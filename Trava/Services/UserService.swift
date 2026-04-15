//  Services/UserService.swift
//  Trava
//
//  Creates or fetches a UserProfile document in Firestore on first login.
//  The document ID equals the Firebase Auth UID.

import Foundation
import FirebaseFirestore
import FirebaseAuth

final class UserService {

    private let db = Firestore.firestore()
    private let collection = "users"

    // MARK: - Create or fetch

    /// Returns the existing profile if one already exists; otherwise creates and returns a new one.
    /// Guest users are skipped — their profile lives only in memory.
    func createOrFetch(for firebaseUser: FirebaseAuth.User) async throws -> UserProfile {
        guard firebaseUser.uid != UserProfile.guestUserId else { return .guest }

        let ref = db.collection(collection).document(firebaseUser.uid)
        let snapshot = try await ref.getDocument()

        if snapshot.exists, let profile = try? snapshot.data(as: UserProfile.self) {
            return profile
        }

        // First login — create the document
        let newProfile = UserProfile(from: firebaseUser)
        try ref.setData(from: newProfile, merge: false)
        return newProfile
    }

    // MARK: - Update

    /// Merges the given fields without overwriting the full document.
    func update(_ profile: UserProfile) async throws {
        guard profile.userId != UserProfile.guestUserId else { return }
        guard let uid = profile.id ?? profile.userId as String? else { return }
        let ref = db.collection(collection).document(uid)
        try ref.setData(from: profile, merge: true)
    }

    // MARK: - Fetch by UID

    func fetch(uid: String) async throws -> UserProfile? {
        guard uid != UserProfile.guestUserId else { return .guest }
        let snapshot = try await db.collection(collection).document(uid).getDocument()
        return try? snapshot.data(as: UserProfile.self)
    }
}
