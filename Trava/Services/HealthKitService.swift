//  Services/HealthKitService.swift
//  Trava
//
//  Read-only HealthKit integration: fetches workout routes and converts them
//  to ExplorationTracks.
//
//  ── Xcode Setup Required ──────────────────────────────────────────────────
//  1. Select the Trava target in Xcode → Signing & Capabilities tab
//  2. Click "+ Capability" and add "HealthKit"
//  3. In Info.plist (or via the Xcode property-list editor) add:
//       Key:   NSHealthShareUsageDescription
//       Value: "Trava imports your walking and running routes to build your city map."
//  (No write permission needed — Trava is read-only.)
//  ──────────────────────────────────────────────────────────────────────────

import Foundation
import CoreLocation
import HealthKit

// MARK: - Errors

enum HealthKitError: LocalizedError {
    case unavailable
    case unauthorized
    case noData

    var errorDescription: String? {
        switch self {
        case .unavailable:  return "HealthKit is not available on this device."
        case .unauthorized: return "Health access was not granted. Open Settings → Health → Data Access & Devices to allow Trava."
        case .noData:       return "No workout routes found in the selected date range."
        }
    }
}

// MARK: - Service

final class HealthKitService {

    static let shared = HealthKitService()
    private init() {}

    private let store = HKHealthStore()

    /// Returns false on devices where HealthKit is unavailable (e.g. iPads without fitness hardware).
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    /// Requests read-only access to workouts and workout routes.
    /// Must be called before any query; safe to call multiple times.
    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.unavailable }
        let types: Set<HKObjectType> = [
            .workoutType(),
            HKSeriesType.workoutRoute()
        ]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    // MARK: - Count

    /// Returns the number of workouts recorded in the given date range.
    /// Useful for showing "12 workouts available" before importing.
    func countWorkouts(from: Date, to: Date) async throws -> Int {
        guard isAvailable else { throw HealthKitError.unavailable }
        let predicate = HKQuery.predicateForSamples(
            withStart: from, end: to, options: .strictStartDate
        )
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType:      .workoutType(),
                predicate:       predicate,
                limit:           HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume(returning: samples?.count ?? 0) }
            }
            store.execute(q)
        }
    }

    // MARK: - Fetch

    /// Fetches all workouts with GPS route data in the date range and converts
    /// them to ExplorationTracks. Workouts without route data are silently skipped.
    /// The `cityName` field defaults to "Unknown City"; callers should reverse-geocode.
    func fetchWorkoutRoutes(
        from: Date,
        to: Date,
        userId: String
    ) async throws -> [ExplorationTrack] {
        guard isAvailable else { throw HealthKitError.unavailable }

        let workouts = try await fetchWorkouts(from: from, to: to)
        var tracks: [ExplorationTrack] = []
        for workout in workouts {
            if let track = try? await buildTrack(from: workout, userId: userId) {
                tracks.append(track)
            }
        }
        return tracks
    }

    // MARK: - Private

    private func fetchWorkouts(from: Date, to: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(
            withStart: from, end: to, options: .strictStartDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType:      .workoutType(),
                predicate:       predicate,
                limit:           HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume(returning: (samples as? [HKWorkout]) ?? []) }
            }
            store.execute(q)
        }
    }

    private func buildTrack(from workout: HKWorkout, userId: String) async throws -> ExplorationTrack? {
        let routes = try await fetchRoutes(for: workout)
        guard let route = routes.first else { return nil }

        let locations = try await fetchLocations(for: route)
        guard !locations.isEmpty else { return nil }

        return ExplorationTrack(
            userId:      userId,
            coordinates: locations.map { Coordinate($0.coordinate) },
            startedAt:   workout.startDate,
            endedAt:     workout.endDate,
            distanceKm:  ExplorationTrack.distance(from: locations),
            cityName:    "Unknown City"
        )
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type:      HKSeriesType.workoutRoute(),
                predicate: predicate,
                anchor:    nil,
                limit:     HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? []) }
            }
            store.execute(q)
        }
    }

    /// HKWorkoutRouteQuery delivers locations in batches; accumulate all before resuming.
    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { cont in
            var accumulated: [CLLocation] = []
            var resumed = false

            let q = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let error {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                    return
                }
                if let batch { accumulated.append(contentsOf: batch) }
                if done {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: accumulated)
                }
            }
            store.execute(q)
        }
    }
}
