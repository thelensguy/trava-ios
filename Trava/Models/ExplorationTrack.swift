//  Models/ExplorationTrack.swift
//  Trava
//
//  Codable model for a recorded exploration session.
//  Stored locally in CoreData, synced to Firestore when online.

import Foundation
import CoreLocation
import FirebaseFirestore

// MARK: - Coordinate (lat/lon pair — Codable, GeoPoint-convertible)

struct Coordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    init(_ clCoordinate: CLLocationCoordinate2D) {
        latitude  = clCoordinate.latitude
        longitude = clCoordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var geoPoint: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }
}

// MARK: - ExplorationTrack

struct ExplorationTrack: Codable, Identifiable {
    // Firestore document ID; not stored in CoreData (trackId is the local key).
    @DocumentID var id: String?

    var trackId: String
    var userId: String
    var coordinates: [Coordinate]
    var startedAt: Date
    var endedAt: Date?
    var distanceKm: Double
    var cityName: String
    /// When true the track may be included in shared snapshots.
    /// Defaults to false — opt-in only.
    var isPublic: Bool

    // Local-only — never written to Firestore.
    var isSynced: Bool

    // MARK: - Init for a new track

    init(
        trackId: String    = UUID().uuidString,
        userId: String,
        coordinates: [Coordinate],
        startedAt: Date,
        endedAt: Date?     = nil,
        distanceKm: Double = 0,
        cityName: String   = "Unknown City",
        isPublic: Bool     = false,
        isSynced: Bool     = false
    ) {
        self.trackId     = trackId
        self.userId      = userId
        self.coordinates = coordinates
        self.startedAt   = startedAt
        self.endedAt     = endedAt
        self.distanceKm  = distanceKm
        self.cityName    = cityName
        self.isPublic    = isPublic
        self.isSynced    = isSynced
    }

    // MARK: - Distance helper

    /// Calculates total path length in km from a list of CLLocations.
    static func distance(from locations: [CLLocation]) -> Double {
        guard locations.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<locations.count {
            total += locations[i].distance(from: locations[i - 1])
        }
        return total / 1_000.0
    }

    /// Same but from a Coordinate array (used when re-hydrating from CoreData).
    static func distance(from coordinates: [Coordinate]) -> Double {
        let locs = coordinates.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        return distance(from: locs)
    }

    // MARK: - Firestore serialisation
    //
    // GeoPoint doesn't round-trip through Codable automatically, so we build
    // the Firestore dictionary manually.

    func firestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "trackId":     trackId,
            "userId":      userId,
            "coordinates": coordinates.map { $0.geoPoint },
            "startedAt":   Timestamp(date: startedAt),
            "distanceKm":  distanceKm,
            "cityName":    cityName,
            "isPublic":    isPublic,
        ]
        if let end = endedAt {
            data["endedAt"] = Timestamp(date: end)
        }
        return data
    }
}
