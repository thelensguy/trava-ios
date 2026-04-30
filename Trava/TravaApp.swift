//  TravaApp.swift
//  Trava

import SwiftUI
import CoreLocation
import FirebaseAuth
import FirebaseCore

@main
struct TravaApp: App {

    @StateObject private var auth            = AuthViewModel()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var trackService    = TrackService()
    @StateObject private var cityService     = CityService()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(locationManager)
                .environmentObject(trackService)
                .environmentObject(cityService)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let userId = auth.currentUserId {
                Task { await activateSession(userId: userId) }
            }
        }
        // Also run when Firebase auth resolves — scenePhase == .active may have
        // already fired before currentUserId was set (async auth listener).
        .onChange(of: auth.currentUserId) { _, userId in
            guard let userId else { return }
            Task { await activateSession(userId: userId) }
        }
        // Save completed passive tracks as they close.
        .onChange(of: locationManager.pendingPassiveTrack) { _, pts in
            guard let pts, !pts.isEmpty,
                  let userId = auth.currentUserId else { return }
            Task {
                let coordinates = pts.map { Coordinate($0.coordinate) }
                let cityName    = await trackService.cityName(for: pts.first?.coordinate)
                let track = ExplorationTrack(
                    userId:      userId,
                    coordinates: coordinates,
                    startedAt:   pts.first?.timestamp ?? Date(),
                    endedAt:     Date(),   // time segment officially closed, not last GPS point
                    distanceKm:  ExplorationTrack.distance(from: pts),
                    cityName:    cityName
                )
                try? await trackService.saveTrackLocally(track)
                // Immediately surface the new track on the map without a
                // round-trip fetch — append directly, then let the city
                // pipeline run in parallel.
                trackService.localTracks.append(track)

                let savedCities = (try? await cityService.detectAndSaveCities(
                    track: track, userId: userId
                )) ?? []
                await cityService.refresh(userId: userId)
                auth.incrementDistanceKm(by: track.distanceKm)
                let newCityCount = savedCities.filter { $0.totalSessions == 1 }.count
                if newCityCount > 0 {
                    auth.incrementCitiesExplored(by: newCityCount)
                }

                // Clear the signal so onChange can fire again next time.
                locationManager.pendingPassiveTrack = nil
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    /// Shared startup sequence: warm cache, reload tracks, then deduplicate cities.
    /// Safe to call multiple times — operations are idempotent.
    @MainActor
    private func activateSession(userId: String) async {
        // Warm cache first so any in-flight city write hits the fast path.
        await cityService.loadCityCache(userId: userId)

        await trackService.refreshLocalTracks(userId: userId)
        await trackService.syncPendingTracks(userId: userId)
        await cityService.refresh(userId: userId)

        // Dedup sweep — merges existing duplicate records.
        // Runs after a short delay so it doesn't block app startup.
        // loadCityCache is called again inside deduplicateAllCities.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await cityService.deduplicateAllCities(userId: userId)

        // Recalculate coverage for all cities using the grid-cell formula.
        // Runs 1s after dedup (3s total from launch) to migrate old point-count values.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await cityService.recalculateAllCoverages(userId: userId)
    }
}
