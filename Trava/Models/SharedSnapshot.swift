//  Models/SharedSnapshot.swift
//  Trava
//
//  Represents a publicly shared city snapshot.
//  Firestore collection path: public/snapshots/{snapshotId}
//
//  A SharedSnapshot is created when a user opts to share a city card.
//  It is world-readable by any authenticated user and appears in the
//  social feed (Phase 5+).

import Foundation
import FirebaseFirestore

struct SharedSnapshot: Codable, Identifiable {

    /// Populated automatically from the Firestore document ID.
    @DocumentID var id: String?

    var snapshotId: String
    var userId: String
    var displayName: String      // denormalised from UserProfile at share time

    var cityName: String
    var country: String
    var coveragePercent: Double  // 0.0 – 1.0, from the City at share time

    /// Optional JPEG/PNG thumbnail rendered from the heatmap.
    /// Stored as Base64 in Firestore; nil if the user didn't attach one.
    var snapshotImageData: Data?

    var createdAt: Date
    var likeCount: Int

    // MARK: - Init

    init(
        snapshotId: String      = UUID().uuidString,
        userId: String,
        displayName: String,
        cityName: String,
        country: String,
        coveragePercent: Double = 0,
        snapshotImageData: Data? = nil,
        createdAt: Date         = Date(),
        likeCount: Int          = 0
    ) {
        self.snapshotId        = snapshotId
        self.userId            = userId
        self.displayName       = displayName
        self.cityName          = cityName
        self.country           = country
        self.coveragePercent   = coveragePercent
        self.snapshotImageData = snapshotImageData
        self.createdAt         = createdAt
        self.likeCount         = likeCount
    }

    // MARK: - Firestore path

    static let collectionPath = "public/snapshots"

    // MARK: - Firestore serialisation

    func firestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "snapshotId":      snapshotId,
            "userId":          userId,
            "displayName":     displayName,
            "cityName":        cityName,
            "country":         country,
            "coveragePercent": coveragePercent,
            "createdAt":       Timestamp(date: createdAt),
            "likeCount":       likeCount,
        ]
        if let img = snapshotImageData {
            data["snapshotImageData"] = img.base64EncodedString()
        }
        return data
    }
}
