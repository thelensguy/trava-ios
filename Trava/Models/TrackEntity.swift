//  Models/TrackEntity.swift
//  Trava
//
//  NSManagedObject subclass for CoreData.
//  The model is built programmatically in PersistenceController — no .xcdatamodeld file needed.
//  Coordinates are stored as JSON-encoded Data.

import CoreData
import Foundation

@objc(TrackEntity)
class TrackEntity: NSManagedObject {

    @NSManaged var trackId: String
    @NSManaged var userId: String
    @NSManaged var coordinatesData: Data     // JSON-encoded [Coordinate]
    @NSManaged var startedAt: Date
    @NSManaged var endedAt: Date?
    @NSManaged var distanceKm: Double
    @NSManaged var cityName: String
    @NSManaged var isPublic: Bool
    @NSManaged var isSynced: Bool

    // MARK: - Conversion helpers

    func toExplorationTrack() -> ExplorationTrack? {
        guard
            let coordinates = try? JSONDecoder().decode([Coordinate].self, from: coordinatesData)
        else { return nil }

        // If distanceKm was stored as 0 (e.g. single-point passive track, or schema
        // migration that reset the field), recalculate from the coordinate path so
        // that all distance totals across the app remain accurate.
        let effectiveDistance = distanceKm > 0
            ? distanceKm
            : ExplorationTrack.distance(from: coordinates)

        return ExplorationTrack(
            trackId:     trackId,
            userId:      userId,
            coordinates: coordinates,
            startedAt:   startedAt,
            endedAt:     endedAt,
            distanceKm:  effectiveDistance,
            cityName:    cityName,
            isPublic:    isPublic
        )
    }

    func configure(from track: ExplorationTrack, in context: NSManagedObjectContext) {
        trackId         = track.trackId
        userId          = track.userId
        startedAt       = track.startedAt
        endedAt         = track.endedAt
        distanceKm      = track.distanceKm
        cityName        = track.cityName
        isPublic        = track.isPublic
        isSynced        = track.isSynced
        coordinatesData = (try? JSONEncoder().encode(track.coordinates)) ?? Data()
    }
}
