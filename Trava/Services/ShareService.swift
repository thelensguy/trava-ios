//  Services/ShareService.swift
//  Trava
//
//  Stub service for the social sharing phase (Phase 5+).
//  Method bodies are intentionally empty; each carries a TODO describing
//  the expected implementation.
//
//  Firestore layout used by this service:
//    public/snapshots/{snapshotId}   — world-readable (see FirestoreRules.txt)

import Foundation
import UIKit
import FirebaseFirestore
import Combine

@MainActor
final class ShareService: ObservableObject {

    private let db = Firestore.firestore()

    // MARK: - Share a city card

    /// Converts `image` to JPEG, builds a SharedSnapshot, and writes it to
    /// Firestore (skipped for guest users or when city.isPublic == false).
    func shareCity(city: City, image: UIImage?, userId: String, displayName: String) async throws {
        let jpegData = image.flatMap { $0.jpegData(compressionQuality: 0.8) }

        let snapshot = SharedSnapshot(
            userId: userId,
            displayName: displayName,
            cityName: city.cityName,
            country: city.country,
            coveragePercent: city.coveragePercent,
            snapshotImageData: jpegData
        )

        // Skip Firestore for guests or cities the user hasn't made public.
        guard userId != UserProfile.guestUserId, city.isPublic else { return }

        // Silent-fail Firestore write — caller already has the image for local share.
        try? await db
            .collection("snapshots")
            .document(snapshot.snapshotId)
            .setData(snapshot.firestoreData())
    }

    // MARK: - Fetch public feed

    /// Returns the most recent SharedSnapshots from all users, ordered by
    /// createdAt descending. Used to populate the social discovery feed.
    ///
    /// TODO (Phase 5):
    ///   1. Query db.collection("public/snapshots")
    ///        .order(by: "createdAt", descending: true)
    ///        .limit(to: 50)
    ///   2. Decode each document as SharedSnapshot via Firestore Codable.
    ///   3. Cache results locally (UserDefaults or CoreData) for offline display.
    func fetchPublicSnapshots() async throws -> [SharedSnapshot] {
        // TODO: implement in Phase 5
        return []
    }

    // MARK: - Like a snapshot

    /// Increments the likeCount on a snapshot by 1.
    /// The Firestore security rule allows any authenticated user to update
    /// ONLY the likeCount field by exactly +1 (see FirestoreRules.txt).
    ///
    /// TODO (Phase 5):
    ///   1. Reject if the caller is a guest user (userId == UserProfile.guestUserId).
    ///   2. Use FieldValue.increment(1) to atomically update likeCount.
    ///   3. Persist a local Set<String> of liked snapshot IDs (UserDefaults)
    ///      so the heart icon stays filled across sessions.
    ///   4. Prevent double-liking by checking the local set before writing.
    func likeSnapshot(snapshotId: String) async throws {
        // TODO: implement in Phase 5
    }
}
