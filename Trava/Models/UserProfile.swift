//  Models/UserProfile.swift
//  Trava
//
//  Firestore data model for a Trava user.

import Foundation
import FirebaseFirestore
import FirebaseAuth

struct UserProfile: Codable, Identifiable {
    // Populated automatically from the Firestore document ID.
    @DocumentID var id: String?

    var userId: String
    var email: String
    var displayName: String
    var createdAt: Date
    var totalCitiesExplored: Int
    var totalDistanceKm: Double
    /// When true the user's displayName may appear in public snapshots.
    /// Defaults to false — opt-in only.
    var isPublic: Bool

    // MARK: - Memberwise init

    init(
        userId: String,
        email: String,
        displayName: String,
        createdAt: Date = Date(),
        totalCitiesExplored: Int = 0,
        totalDistanceKm: Double = 0.0,
        isPublic: Bool = false
    ) {
        self.userId              = userId
        self.email               = email
        self.displayName         = displayName
        self.createdAt           = createdAt
        self.totalCitiesExplored = totalCitiesExplored
        self.totalDistanceKm     = totalDistanceKm
        self.isPublic            = isPublic
    }

    // MARK: - Init from a freshly authenticated Firebase user

    init(from firebaseUser: FirebaseAuth.User) {
        self.userId              = firebaseUser.uid
        self.email               = firebaseUser.email ?? ""
        self.displayName         = firebaseUser.displayName
                                   ?? firebaseUser.email?.components(separatedBy: "@").first
                                   ?? "Explorer"
        self.createdAt           = Date()
        self.totalCitiesExplored = 0
        self.totalDistanceKm     = 0.0
        self.isPublic            = false
    }

    // MARK: - Guest profile

    static let guestUserId = "guest-user"

    static let guest = UserProfile(
        userId:      guestUserId,
        email:       "guest@trava.app",
        displayName: "Explorer"
    )
}
