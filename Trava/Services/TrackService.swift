//  Services/TrackService.swift
//  Trava
//
//  Offline-first track persistence:
//    1. saveTrackLocally()   — writes to CoreData immediately
//    2. syncPendingTracks()  — uploads unsynced tracks to Firestore, marks them synced
//
//  Call syncPendingTracks() on:
//    • App foreground (scenePhase .active)
//    • Connectivity restore (NWPathMonitor)

import Combine
import CoreData
import CoreLocation
import Foundation
import MapKit
import FirebaseFirestore

@MainActor
final class TrackService: ObservableObject {

    @Published var isSyncing    = false
    /// Cached tracks for the current session — cleared automatically on store reset.
    @Published var localTracks: [ExplorationTrack] = []

    private let persistence = PersistenceController.shared
    private let db          = Firestore.firestore()
    private var resetObserver: NSObjectProtocol?

    init() {
        resetObserver = NotificationCenter.default.addObserver(
            forName: PersistenceController.didResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localTracks = []
                self?.isSyncing   = false
            }
        }
    }

    // MARK: - Save locally (CoreData, offline-safe)

    func saveTrackLocally(_ track: ExplorationTrack) async throws {
        print("[TrackService] saving: city='\(track.cityName)' distanceKm=\(track.distanceKm) coords=\(track.coordinates.count)")
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let entity = TrackEntity(context: context)
            entity.configure(from: track, in: context)
            try context.save()
        }
        print("[TrackService] saved to CoreData ✓")
    }

    // MARK: - Load local tracks for a user

    /// Loads and caches tracks into `localTracks` for reactive UI binding.
    func refreshLocalTracks(userId: String) async {
        localTracks = (try? await loadLocalTracks(userId: userId)) ?? []
    }

    func loadLocalTracks(userId: String) async throws -> [ExplorationTrack] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<TrackEntity>(entityName: "TrackEntity")
            request.predicate = NSPredicate(format: "userId == %@", userId)
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

            let entities = try context.fetch(request)
            return entities.compactMap { $0.toExplorationTrack() }
        }
    }

    // MARK: - Sync pending tracks to Firestore

    /// Finds all unsynced CoreData tracks and uploads them.
    /// Safe to call repeatedly — already-synced tracks are skipped.
    /// Guest users are local-only; Firestore upload is skipped.
    func syncPendingTracks(userId: String) async {
        guard userId != UserProfile.guestUserId else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let context = persistence.container.newBackgroundContext()

        do {
            // 1. Fetch unsynced entities.
            let unsynced: [TrackEntity] = try await context.perform {
                let request = NSFetchRequest<TrackEntity>(entityName: "TrackEntity")
                request.predicate = NSPredicate(
                    format: "userId == %@ AND isSynced == NO", userId
                )
                return try context.fetch(request)
            }

            guard !unsynced.isEmpty else { return }

            // 2. Upload each, mark as synced on success.
            for entity in unsynced {
                // Extract objectID (Sendable) before any @Sendable closure so
                // the non-Sendable TrackEntity is never captured across an async boundary.
                let objectID = entity.objectID
                let track = await context.perform {
                    (context.object(with: objectID) as? TrackEntity)?.toExplorationTrack()
                }
                guard let track else { continue }

                do {
                    let docRef = db
                        .collection("users").document(userId)
                        .collection("tracks").document(track.trackId)
                    try await docRef.setData(track.firestoreData())

                    // 3. Mark synced using the Sendable objectID.
                    try await context.perform {
                        if let e = context.object(with: objectID) as? TrackEntity {
                            e.isSynced = true
                            try context.save()
                        }
                    }
                } catch {
                    print("[TrackService] Upload failed for \(track.trackId): \(error)")
                    // Leave isSynced = false so it retries next time.
                }
            }
        } catch {
            print("[TrackService] Sync error: \(error)")
        }
    }

    // MARK: - Reverse-geocode city name

    /// Returns the city name for a coordinate, or "Unknown City" on failure.
    func cityName(for coordinate: CLLocationCoordinate2D?) async -> String {
        guard let coordinate else { return "Unknown City" }
        let item = await reverseGeocode(coordinate: coordinate)
        return item?.addressRepresentations?.cityName ?? item?.addressRepresentations?.cityWithContext ?? "Unknown City"
    }

    private func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        return try? await request.mapItems.first
    }
}
