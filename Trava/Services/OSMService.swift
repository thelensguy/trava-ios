//  Services/OSMService.swift
//  Trava
//
//  Fetches city boundary polygons from OpenStreetMap Nominatim API.
//  Results are cached in CoreData (CityBoundaryEntity) for 30 days.
//  Failed lookups are cached for 7 days to prevent repeated Nominatim hammering.
//
//  Nominatim usage policy:
//    • User-Agent header identifying the app is required.
//    • Max 1 request per second — enforced via enforceRateLimit().
//    • https://operations.osmfoundation.org/policies/nominatim/

import Foundation
import CoreData
import CoreLocation

actor OSMService {

    /// Shared singleton.  @MainActor so PersistenceController.shared (also @MainActor)
    /// can be safely captured at initialisation time.
    @MainActor static let shared = OSMService(persistence: PersistenceController.shared)

    private let persistence: PersistenceController
    private var lastRequestTime: Date?

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    private static let positiveCacheDuration: TimeInterval = 30 * 24 * 3_600  // 30 days
    private static let negativeCacheDuration:  TimeInterval =  7 * 24 * 3_600  //  7 days
    private static let userAgent = "Trava/1.0 (iOS exploration-tracking app)"

    // MARK: - Public API

    /// Returns the outer boundary ring for a city as [lon, lat] pairs.
    ///
    /// Fallback chain (each attempt separated by ≥0.5 s to respect Nominatim limits):
    ///   1. city=<name>&country=<country>          — structured query
    ///   2. q=<name>, <adminArea>, <country>       — free-text with full context
    ///   3. q=<name>, <adminArea>                  — drop country (if adminArea available)
    ///   4a. /reverse?zoom=10                      — nearest city-level boundary at coords
    ///   4b. /reverse?zoom=8                       — nearest county-level boundary at coords
    ///
    /// Failed lookups (all attempts exhausted) are cached for 7 days as a negative
    /// record (empty coordinatesData) so Nominatim is not hit again until the TTL expires.
    func fetchCityBoundary(
        cityName:           String,
        country:            String,
        countryCode:        String = "",
        administrativeArea: String? = nil,
        coordinates:        CLLocationCoordinate2D? = nil
    ) async -> [[Double]]? {
        // Cache check — returns nil on miss, [] on negative hit, [[Double]] on positive hit.
        if let cached = await loadFromCache(cityName: cityName, country: country) {
            return cached.isEmpty ? nil : cached
        }

        // ── Attempt 1: structured city= query ───────────────────────────────
        await enforceRateLimit(minInterval: 1.0)
        if let coords = await fetchByCityParam(cityName: cityName, country: country, countryCode: countryCode),
           coords.count >= 3 {
            await saveToCache(cityName: cityName, country: country, coords: coords)
            return coords
        }

        // ── Attempt 2: free-text q= with admin area + country ───────────────
        // Use ISO code in q= when available ("San Francisco, California, us")
        // — more precise than the full country name for Nominatim free-text.
        await enforceRateLimit(minInterval: 0.5)
        let countryPart = countryCode.isEmpty ? country : countryCode
        let q2: String = {
            if let admin = administrativeArea, !admin.isEmpty {
                return "\(cityName), \(admin), \(countryPart)"
            }
            return "\(cityName), \(countryPart)"
        }()
        if let coords = await fetchByQ(q2), coords.count >= 3 {
            await saveToCache(cityName: cityName, country: country, coords: coords)
            return coords
        }

        // ── Attempt 3: free-text q= with admin area only (drop country) ─────
        if let admin = administrativeArea, !admin.isEmpty {
            await enforceRateLimit(minInterval: 0.5)
            if let coords = await fetchByQ("\(cityName), \(admin)"), coords.count >= 3 {
                await saveToCache(cityName: cityName, country: country, coords: coords)
                return coords
            }
        }

        // ── Attempt 4: Nominatim reverse geocode (parent admin boundary) ────
        if let coord = coordinates {
            await enforceRateLimit(minInterval: 0.5)
            if let coords = await fetchByReverse(lat: coord.latitude, lon: coord.longitude, zoom: 10),
               coords.count >= 3 {
                await saveToCache(cityName: cityName, country: country, coords: coords)
                return coords
            }

            await enforceRateLimit(minInterval: 0.5)
            if let coords = await fetchByReverse(lat: coord.latitude, lon: coord.longitude, zoom: 8),
               coords.count >= 3 {
                await saveToCache(cityName: cityName, country: country, coords: coords)
                return coords
            }
        }

        // All attempts failed — write negative cache to suppress retries for 7 days.
        await saveToCache(cityName: cityName, country: country, coords: [])
        return nil
    }

    // MARK: - Rate limiting

    private func enforceRateLimit(minInterval: TimeInterval) async {
        if let last = lastRequestTime {
            let wait = minInterval - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    // MARK: - Fetch helpers

    private func fetchByCityParam(cityName: String, country: String, countryCode: String) async -> [[Double]]? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        // countrycodes= (ISO 3166-1 alpha-2) is more reliable than country= (full name).
        let countryItem = countryCode.isEmpty
            ? URLQueryItem(name: "country",      value: country)
            : URLQueryItem(name: "countrycodes", value: countryCode)
        components.queryItems = [
            URLQueryItem(name: "city",            value: cityName),
            countryItem,
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "format",          value: "geojson"),
            URLQueryItem(name: "limit",           value: "1"),
        ]
        return await fetchAndParseCollection(components)
    }

    private func fetchByQ(_ q: String) async -> [[Double]]? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q",               value: q),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "format",          value: "geojson"),
            URLQueryItem(name: "limit",           value: "1"),
        ]
        return await fetchAndParseCollection(components)
    }

    private func fetchByReverse(lat: Double, lon: Double, zoom: Int) async -> [[Double]]? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "lat",             value: String(lat)),
            URLQueryItem(name: "lon",             value: String(lon)),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "format",          value: "geojson"),
            URLQueryItem(name: "zoom",            value: String(zoom)),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        // /reverse returns a single Feature, not a FeatureCollection.
        return parseGeoJSONFeature(data)
    }

    private func fetchAndParseCollection(_ components: URLComponents) async -> [[Double]]? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parseGeoJSONCollection(data)
    }

    // MARK: - GeoJSON parsers

    /// Parses a Nominatim /search response (FeatureCollection).
    private func parseGeoJSONCollection(_ data: Data) -> [[Double]]? {
        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = json["features"] as? [[String: Any]],
            let first    = features.first,
            let geometry = first["geometry"] as? [String: Any],
            let type     = geometry["type"] as? String
        else { return nil }
        return extractOuterRing(from: geometry, type: type)
    }

    /// Parses a Nominatim /reverse response (single Feature).
    private func parseGeoJSONFeature(_ data: Data) -> [[Double]]? {
        guard
            let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let geometry = json["geometry"] as? [String: Any],
            let type     = geometry["type"] as? String
        else { return nil }
        return extractOuterRing(from: geometry, type: type)
    }

    private func extractOuterRing(from geometry: [String: Any], type: String) -> [[Double]]? {
        switch type {
        case "Polygon":
            // [[[lon, lat]]] — first element is the outer ring.
            let rings = geometry["coordinates"] as? [[[Double]]]
            return rings?.first

        case "MultiPolygon":
            // [[[[lon, lat]]]] — take largest polygon's outer ring.
            guard let polys = geometry["coordinates"] as? [[[[Double]]]] else { return nil }
            return polys.max(by: { ($0.first?.count ?? 0) < ($1.first?.count ?? 0) })?.first

        default:
            return nil
        }
    }

    // MARK: - Cache read

    /// Returns:
    ///   • nil          — cache miss; caller should fetch from Nominatim
    ///   • []           — negative cache hit; caller should return nil without fetching
    ///   • [[Double]]   — positive cache hit; caller should return the boundary
    private func loadFromCache(cityName: String, country: String) async -> [[Double]]? {
        let context = persistence.container.newBackgroundContext()
        return await context.perform {
            let req = NSFetchRequest<CityBoundaryEntity>(entityName: "CityBoundaryEntity")
            req.predicate  = NSPredicate(
                format: "cityName ==[c] %@ AND country ==[c] %@", cityName, country
            )
            req.fetchLimit = 1
            guard let entity = try? context.fetch(req).first else { return nil }

            let isNegative = entity.coordinatesData.isEmpty
            let ttl        = isNegative ? OSMService.negativeCacheDuration : OSMService.positiveCacheDuration
            let age        = Date().timeIntervalSince(entity.fetchedAt)

            if age > ttl {
                context.delete(entity)
                try? context.save()
                return nil   // expired — caller will re-fetch
            }

            if isNegative { return [] }   // within negative TTL — skip Nominatim

            return try? JSONDecoder().decode([[Double]].self, from: entity.coordinatesData)
        }
    }

    // MARK: - Cache write

    /// Saves a boundary result.  Pass coords: [] to write a negative cache record.
    private func saveToCache(cityName: String, country: String, coords: [[Double]]) async {
        let context = persistence.container.newBackgroundContext()
        await context.perform {
            let req = NSFetchRequest<CityBoundaryEntity>(entityName: "CityBoundaryEntity")
            req.predicate = NSPredicate(
                format: "cityName ==[c] %@ AND country ==[c] %@", cityName, country
            )
            (try? context.fetch(req))?.forEach { context.delete($0) }

            let entity             = CityBoundaryEntity(context: context)
            entity.cityName        = cityName
            entity.country         = country
            // Empty Data() is the negative-cache sentinel — DO NOT encode [] as JSON here.
            entity.coordinatesData = coords.isEmpty
                ? Data()
                : ((try? JSONEncoder().encode(coords)) ?? Data())
            entity.fetchedAt       = Date()
            try? context.save()
        }
    }
}
