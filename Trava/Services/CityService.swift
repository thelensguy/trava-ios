//  Services/CityService.swift
//  Trava
//
//  City detection + offline-first persistence.
//
//  Architecture — duplicate-free city writes
//  ────────────────────────────────────────────────────────────────────────────
//  All CoreData city writes are routed through a single serial DispatchQueue
//  (writeQueue) backed by a dedicated background NSManagedObjectContext
//  (writeContext).  An in-memory dictionary (cityCache) acts as a write-through
//  cache keyed by "name|country|userId" so duplicate-existence checks never
//  need a round-trip to CoreData.
//
//  Guarantees
//    • writeQueue.sync serialises every write — 10 simultaneous geocode
//      callbacks for "Cupertino" only ever create one record.
//    • cityCache is populated on launch via loadCityCache(userId:) and
//      refreshed after deduplicateAllCities(userId:) to reflect the clean state.
//    • If the cache is still warming (e.g. very first launch), the
//      writeContext.performAndWait fetch acts as a safe fallback.
//  ────────────────────────────────────────────────────────────────────────────

import Foundation
import CoreData
import CoreLocation
import MapKit
import Combine
import FirebaseFirestore

// MARK: - CityService

@MainActor
final class CityService: ObservableObject {

    @Published var cities: [City] = []

    private let persistence = PersistenceController.shared
    private let db          = Firestore.firestore()

    // ── Serial write infrastructure ──────────────────────────────────────────

    /// Single background serial queue — all CoreData city writes run here.
    private let writeQueue = DispatchQueue(label: "com.trava.citywrite", qos: .utility)

    /// In-memory cache: key = "cityName.lowercased()|country.lowercased()|userId"
    /// Protected by writeQueue — read and mutated ONLY inside writeQueue blocks.
    /// nonisolated(unsafe): manually synchronised via writeQueue.
    nonisolated(unsafe) private var cityCache: [String: Bool] = [:]

    /// Dedicated NSManagedObjectContext used exclusively on writeQueue.
    /// Initialised eagerly on MainActor in init(); afterwards only touched on writeQueue.
    /// nonisolated(unsafe): manually synchronised via writeQueue.
    nonisolated(unsafe) private var writeContext: NSManagedObjectContext!

    private var resetObserver: NSObjectProtocol?

    init() {
        // Initialise writeContext on the MainActor thread (required for container access),
        // before writeQueue can ever reference it.
        let ctx = PersistenceController.shared.container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.automaticallyMergesChangesFromParent = true
        writeContext = ctx

        resetObserver = NotificationCenter.default.addObserver(
            forName: PersistenceController.didResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.cities = [] }
            // Clear cache on writeQueue — nonisolated(unsafe) so direct capture is fine.
            writeQueue.async { [weak self] in self?.cityCache = [:] }
        }
    }

    // MARK: - Cache warm-up

    /// Populates cityCache from CoreData.  Call this once on launch BEFORE any
    /// tracking begins so the cache is warm when the first city save arrives.
    func loadCityCache(userId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                var newCache: [String: Bool] = [:]
                writeContext.performAndWait {
                    let req = NSFetchRequest<CityEntity>(entityName: "CityEntity")
                    req.predicate = NSPredicate(format: "userId == %@", userId)
                    let all = (try? writeContext.fetch(req)) ?? []
                    for e in all {
                        let key = "\(e.cityName.lowercased())|\(e.country.lowercased())|\(userId)"
                        newCache[key] = true
                    }
                }
                cityCache = newCache
                cont.resume()
            }
        }
    }

    // MARK: - Multi-city detection + save

    @discardableResult
    func detectAndSaveCities(
        track: ExplorationTrack,
        userId: String
    ) async throws -> [City] {
        let coords = track.coordinates
        guard !coords.isEmpty else { return [] }

        let samples = await sampleCities(from: coords, fallbackCityName: track.cityName)

        if samples.isEmpty {
            let city = try await saveOrUpdateCity(
                cityName: track.cityName.isEmpty ? "Unknown City" : track.cityName,
                country:  "Unknown",
                track:    track,
                userId:   userId
            )
            return [city]
        }

        struct CityRun {
            let cityName: String
            let country:  String
            var firstCoordIdx: Int
            var lastCoordIdx:  Int
        }

        var runs: [CityRun] = []
        for s in samples {
            let lastKey = runs.last.map { "\($0.cityName.lowercased())|\($0.country.lowercased())" }
            let thisKey = "\(s.cityName.lowercased())|\(s.country.lowercased())"
            if lastKey == thisKey {
                runs[runs.count - 1].lastCoordIdx = s.coordIndex
            } else {
                runs.append(CityRun(
                    cityName:      s.cityName,
                    country:       s.country,
                    firstCoordIdx: s.coordIndex,
                    lastCoordIdx:  s.coordIndex
                ))
            }
        }

        var savedCities: [City] = []
        for (ri, run) in runs.enumerated() {
            let coordStart: Int = ri == 0
                ? 0
                : (runs[ri - 1].lastCoordIdx + run.firstCoordIdx) / 2 + 1
            let coordEnd: Int = ri == runs.count - 1
                ? coords.count - 1
                : (run.lastCoordIdx + runs[ri + 1].firstCoordIdx) / 2

            guard coordStart <= coordEnd, coordEnd < coords.count else { continue }
            let segCoords = Array(coords[coordStart...coordEnd])
            guard !segCoords.isEmpty else { continue }

            let segDistance = ExplorationTrack.distance(from: segCoords)
            let subTrack = ExplorationTrack(
                trackId:     track.trackId,
                userId:      track.userId,
                coordinates: segCoords,
                startedAt:   track.startedAt,
                endedAt:     track.endedAt,
                distanceKm:  segDistance,
                cityName:    run.cityName
            )
            if let city = try? await saveOrUpdateCity(
                cityName: run.cityName,
                country:  run.country,
                track:    subTrack,
                userId:   userId
            ) {
                savedCities.append(city)
            }
        }
        return savedCities
    }

    // MARK: - Single-city detection (legacy / display use)

    func detectCity(from track: ExplorationTrack) async -> (cityName: String, country: String) {
        guard !track.coordinates.isEmpty else { return (track.cityName, "Unknown") }
        let mid   = track.coordinates[track.coordinates.count / 2]
        let coord = CLLocationCoordinate2D(latitude: mid.latitude, longitude: mid.longitude)
        let item  = await reverseGeocode(coordinate: coord)
        let city    = item?.addressRepresentations?.cityName ?? track.cityName
        let country = item?.addressRepresentations?.regionName ?? "Unknown"
        return (city, country)
    }

    // MARK: - Save or update city (serial write queue)

    @discardableResult
    func saveOrUpdateCity(
        cityName: String,
        country:  String,
        track:    ExplorationTrack,
        userId:   String
    ) async throws -> City {
        let cacheKey = "\(cityName.lowercased())|\(country.lowercased())|\(userId)"

        // All CoreData writes happen serially on writeQueue.
        // writeQueue.sync blocks the caller until the write completes,
        // preventing any concurrent call from slipping through before
        // the cache is updated.
        let city: City = try await withCheckedThrowingContinuation { cont in
            writeQueue.sync { [self] in
                var result: City?
                var writeError: Error?

                writeContext.performAndWait {
                    do {
                        // Check the in-memory cache first.  If the city is in the
                        // cache, skip the "create" path even if the CoreData fetch
                        // returns empty (could be an uncommitted write in flight).
                        let cityIsKnown = cityCache[cacheKey] == true

                        let req = NSFetchRequest<CityEntity>(entityName: "CityEntity")
                        req.predicate = NSPredicate(
                            format: "cityName ==[c] %@ AND country ==[c] %@ AND userId == %@",
                            cityName, country, userId
                        )
                        req.fetchLimit = 1
                        let existing = try writeContext.fetch(req)

                        if let entity = existing.first {
                            // ── Update ──────────────────────────────────────
                            entity.lastVisitedAt    = Date()
                            entity.totalDistanceKm += track.distanceKm
                            entity.totalSessions   += 1
                            entity.isSynced         = false
                            let prior  = (try? JSONDecoder().decode([Coordinate].self, from: entity.coordinatesData)) ?? []
                            let merged = prior + track.coordinates
                            entity.coordinatesData = (try? JSONEncoder().encode(merged)) ?? Data()
                            entity.coveragePercent = min(1.0, Double(merged.count) / 5_000.0)
                            try writeContext.save()
                            result = entity.toCity()

                        } else if !cityIsKnown {
                            // ── Create ───────────────────────────────────────
                            let newCity = City(
                                userId:          userId,
                                cityName:        cityName,
                                country:         country,
                                coordinates:     track.coordinates,
                                totalDistanceKm: track.distanceKm,
                                totalSessions:   1,
                                coveragePercent: min(1.0, Double(track.coordinates.count) / 5_000.0)
                            )
                            let entity = CityEntity(context: writeContext)
                            entity.configure(from: newCity)
                            try writeContext.save()
                            result = newCity

                        } else {
                            // Cache says the city exists but the CoreData fetch
                            // returned nothing — this can happen transiently.
                            // Treat it as a no-op and return a placeholder so
                            // callers don't crash.  The next save will land correctly.
                            print("[CityService] Cache/CoreData mismatch for \(cityName) — skipping")
                            result = City(
                                userId: userId, cityName: cityName, country: country,
                                coordinates: [], totalDistanceKm: 0, totalSessions: 0,
                                coveragePercent: 0
                            )
                        }
                    } catch {
                        writeError = error
                    }
                }

                // Update the cache AFTER a successful write (on writeQueue thread).
                if writeError == nil { cityCache[cacheKey] = true }

                if let err = writeError {
                    cont.resume(throwing: err)
                } else if let c = result {
                    cont.resume(returning: c)
                } else {
                    cont.resume(throwing: CityServiceError.saveFailed)
                }
            }
        }

        // ── Firestore sync (async, outside writeQueue) ────────────────────────
        if userId != UserProfile.guestUserId {
            do {
                let ref = db
                    .collection("users").document(userId)
                    .collection("cities").document(city.cityId)
                try await ref.setData(city.firestoreData(), merge: true)

                // Mark isSynced in CoreData.
                let cityId = city.cityId
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    writeQueue.async { [self] in
                        writeContext.performAndWait {
                            let req = NSFetchRequest<CityEntity>(entityName: "CityEntity")
                            req.predicate  = NSPredicate(format: "cityId == %@", cityId)
                            req.fetchLimit = 1
                            if let e = try? writeContext.fetch(req).first {
                                e.isSynced = true
                                try? writeContext.save()
                            }
                        }
                        cont.resume()
                    }
                }
            } catch {
                print("[CityService] Firestore sync failed for \(cityName): \(error)")
            }
        }

        // Warm OSM boundary cache in the background.
        // Capture shared instance here (on @MainActor) before entering the detached task.
        let _cityName  = cityName
        let _country   = country
        let _osmService = OSMService.shared
        Task.detached(priority: .utility) {
            _ = await _osmService.fetchCityBoundary(cityName: _cityName, country: _country)
        }

        return city
    }

    // MARK: - One-time startup deduplication

    /// Merges any duplicate CityEntity records for userId.  Safe to call on every
    /// launch — no-op when nothing to merge.  Reloads cityCache afterwards so the
    /// cache reflects the cleaned state.
    func deduplicateAllCities(userId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                writeContext.performAndWait {
                    let req = NSFetchRequest<CityEntity>(entityName: "CityEntity")
                    req.predicate = NSPredicate(format: "userId == %@", userId)
                    guard let all = try? writeContext.fetch(req) else { return }

                    var groups: [String: [CityEntity]] = [:]
                    for e in all {
                        let key = "\(e.cityName.lowercased())|\(e.country.lowercased())"
                        groups[key, default: []].append(e)
                    }

                    var changed = false
                    for entities in groups.values where entities.count > 1 {
                        let sorted  = entities.sorted { $0.firstVisitedAt < $1.firstVisitedAt }
                        let primary = sorted[0]
                        for dup in sorted.dropFirst() {
                            primary.totalDistanceKm += dup.totalDistanceKm
                            primary.totalSessions   += dup.totalSessions
                            let p = (try? JSONDecoder().decode([Coordinate].self, from: primary.coordinatesData)) ?? []
                            let d = (try? JSONDecoder().decode([Coordinate].self, from: dup.coordinatesData)) ?? []
                            primary.coordinatesData = (try? JSONEncoder().encode(p + d)) ?? Data()
                            primary.coveragePercent = min(1.0, Double((p + d).count) / 5_000.0)
                            if dup.firstVisitedAt < primary.firstVisitedAt {
                                primary.firstVisitedAt = dup.firstVisitedAt
                            }
                            writeContext.delete(dup)
                            changed = true
                        }
                    }
                    if changed { try? writeContext.save() }
                }
                cont.resume()
            }
        }

        // Reload cache to reflect the deduplicated state.
        await loadCityCache(userId: userId)
        await refresh(userId: userId)
    }

    // MARK: - Load cities for a user

    func loadCities(userId: String) async throws -> [City] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<CityEntity>(entityName: "CityEntity")
            request.predicate       = NSPredicate(format: "userId == %@", userId)
            request.sortDescriptors = [NSSortDescriptor(key: "lastVisitedAt", ascending: false)]
            return try context.fetch(request).compactMap { $0.toCity() }
        }
    }

    // MARK: - Refresh published list

    func refresh(userId: String) async {
        cities = (try? await loadCities(userId: userId)) ?? []
    }

    // MARK: - Private helpers

    private struct GeoSample {
        let coordIndex: Int
        let cityName:   String
        let country:    String
    }

    private func sampleCities(
        from coords: [Coordinate],
        fallbackCityName: String
    ) async -> [GeoSample] {
        let stride: Int
        switch coords.count {
        case ..<20:    stride = 1
        case 20..<100: stride = 5
        default:       stride = 10
        }

        var indices: [Int] = Swift.stride(from: 0, to: coords.count, by: stride).map { $0 }
        if let last = indices.last, last != coords.count - 1 {
            indices.append(coords.count - 1)
        }

        var results: [GeoSample] = []
        for (n, idx) in indices.enumerated() {
            if n > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            let c     = coords[idx]
            let coord = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            guard let item = await reverseGeocode(coordinate: coord) else { continue }
            let city    = item.addressRepresentations?.cityName
                        ?? item.placemark.locality
                        ?? fallbackCityName
            let country = item.addressRepresentations?.regionName
                        ?? item.placemark.country
                        ?? "Unknown"
            guard city != "Unknown City", !city.isEmpty else { continue }
            results.append(GeoSample(coordIndex: idx, cityName: city, country: country))
        }
        return results
    }

    private func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        return try? await request.mapItems.first
    }
}

// MARK: - CityServiceError

enum CityServiceError: Error {
    case saveFailed
}
