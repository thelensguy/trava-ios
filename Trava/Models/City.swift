//  Models/City.swift
//  Trava
//
//  Represents a metropolitan area the user has explored.
//  Stored locally in CoreData (CityEntity) and synced to Firestore.

import Foundation
import CoreData
import CoreLocation
import FirebaseFirestore

// MARK: - City

struct City: Codable, Identifiable {
    /// Stable local identifier — always set, never nil.
    var id: String { cityId }

    var cityId: String
    var userId: String
    var cityName: String
    var country: String
    var firstVisitedAt: Date
    var lastVisitedAt: Date
    var coordinates: [Coordinate]   // all sampled coords within this city
    var totalDistanceKm: Double
    var totalSessions: Int
    var coveragePercent: Double     // 0.0 – 1.0

    /// When true the city card may appear in the user's public profile / snapshots.
    /// Defaults to false — opt-in only.
    var isPublic: Bool

    // Local-only — never written to Firestore.
    var isSynced: Bool

    init(
        cityId: String = UUID().uuidString,
        userId: String,
        cityName: String,
        country: String,
        firstVisitedAt: Date = Date(),
        lastVisitedAt: Date = Date(),
        coordinates: [Coordinate] = [],
        totalDistanceKm: Double = 0,
        totalSessions: Int = 0,
        coveragePercent: Double = 0,
        isPublic: Bool = false,
        isSynced: Bool = false
    ) {
        self.cityId          = cityId
        self.userId          = userId
        self.cityName        = cityName
        self.country         = country
        self.firstVisitedAt  = firstVisitedAt
        self.lastVisitedAt   = lastVisitedAt
        self.coordinates     = coordinates
        self.totalDistanceKm = totalDistanceKm
        self.totalSessions   = totalSessions
        self.coveragePercent = coveragePercent
        self.isPublic        = isPublic
        self.isSynced        = isSynced
    }

    // MARK: - Firestore serialisation (GeoPoint doesn't round-trip Codable)

    func firestoreData() -> [String: Any] {
        [
            "cityId":          cityId,
            "userId":          userId,
            "cityName":        cityName,
            "country":         country,
            "firstVisitedAt":  Timestamp(date: firstVisitedAt),
            "lastVisitedAt":   Timestamp(date: lastVisitedAt),
            "coordinates":     coordinates.map { $0.geoPoint },
            "totalDistanceKm": totalDistanceKm,
            "totalSessions":   totalSessions,
            "coveragePercent": coveragePercent,
            "isPublic":        isPublic,
        ]
    }
}

// MARK: - CityEntity (CoreData NSManagedObject)

@objc(CityEntity)
final class CityEntity: NSManagedObject {
    @NSManaged var cityId: String
    @NSManaged var userId: String
    @NSManaged var cityName: String
    @NSManaged var country: String
    @NSManaged var firstVisitedAt: Date
    @NSManaged var lastVisitedAt: Date
    @NSManaged var coordinatesData: Data    // JSON-encoded [Coordinate]
    @NSManaged var totalDistanceKm: Double
    @NSManaged var totalSessions: Int32
    @NSManaged var coveragePercent: Double
    @NSManaged var isPublic: Bool
    @NSManaged var isSynced: Bool

    func toCity() -> City? {
        let coords = (try? JSONDecoder().decode([Coordinate].self, from: coordinatesData)) ?? []
        return City(
            cityId:          cityId,
            userId:          userId,
            cityName:        cityName,
            country:         country,
            firstVisitedAt:  firstVisitedAt,
            lastVisitedAt:   lastVisitedAt,
            coordinates:     coords,
            totalDistanceKm: totalDistanceKm,
            totalSessions:   Int(totalSessions),
            coveragePercent: coveragePercent,
            isPublic:        isPublic
        )
    }

    func configure(from city: City) {
        cityId          = city.cityId
        userId          = city.userId
        cityName        = city.cityName
        country         = city.country
        firstVisitedAt  = city.firstVisitedAt
        lastVisitedAt   = city.lastVisitedAt
        coordinatesData = (try? JSONEncoder().encode(city.coordinates)) ?? Data()
        totalDistanceKm = city.totalDistanceKm
        totalSessions   = Int32(city.totalSessions)
        coveragePercent = city.coveragePercent
        isPublic        = city.isPublic
        isSynced        = city.isSynced
    }
}

// MARK: - CityBoundaryEntity (CoreData NSManagedObject)
// Shared OSM boundary cache — NOT per-user, keyed by cityName + country.

@objc(CityBoundaryEntity)
final class CityBoundaryEntity: NSManagedObject {
    @NSManaged var cityName: String
    @NSManaged var country: String
    /// JSON-encoded [[Double]] — each inner array is [longitude, latitude].
    @NSManaged var coordinatesData: Data
    @NSManaged var fetchedAt: Date
}
