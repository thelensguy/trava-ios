//  AuthViewModel.swift
//  Trava
//
//  Manages Firebase Authentication state and sign-in flows:
//    • Sign in with Apple  (AuthenticationServices — no extra package needed)
//    • Google Sign-In      (requires GoogleSignIn-iOS SPM package — see README)
//    • Email / Password
//
//  NOTE — Google Sign-In setup:
//    1. Add the GoogleSignIn-iOS package via SPM:
//       https://github.com/google/GoogleSignIn-iOS
//    2. In your Info.plist, add a URL scheme equal to your REVERSED_CLIENT_ID
//       from GoogleService-Info.plist (looks like com.googleusercontent.apps.xxx)

import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
import FirebaseCore
import FirebaseAuth

// Uncomment once GoogleSignIn-iOS is added via SPM:
 import GoogleSignIn

@MainActor
final class AuthViewModel: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var firebaseUser: FirebaseAuth.User?
    @Published var userProfile: UserProfile?
    @Published var isLoading = false
    @Published var authError: String?

    /// True when the user chose "Continue without account".
    /// Persisted in UserDefaults so it survives relaunches during testing.
    @Published var isGuest: Bool

    // MARK: - Dependencies

    private let userService = UserService()
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    private static let guestKey = "trava.isGuestUser"

    // MARK: - Apple sign-in bridge

    private var appleSignInContinuation: CheckedContinuation<ASAuthorization, Error>?
    private var currentNonce: String?

    // MARK: - Init

    override init() {
        isGuest = UserDefaults.standard.bool(forKey: Self.guestKey)
        super.init()

        // Restore guest profile on relaunch.
        if isGuest { userProfile = .guest }

        // Listen to Firebase auth state changes for the entire app lifetime.
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.firebaseUser = user
                if let user {
                    self.userProfile = try? await self.userService.createOrFetch(for: user)
                } else if !self.isGuest {
                    self.userProfile = nil
                }
            }
        }
    }

    // MARK: - Guest mode

    /// Bypass Firebase Auth for local-only / simulator testing.
    func continueAsGuest() {
        isGuest = true
        userProfile = .guest
        UserDefaults.standard.set(true, forKey: Self.guestKey)
    }

    /// The active user ID regardless of auth method.
    var currentUserId: String? {
        if isGuest { return UserProfile.guestUserId }
        return firebaseUser?.uid
    }

    // MARK: - Sign In with Apple

    func signInWithApple() async {
        isLoading = true
        authError = nil
        defer { isLoading = false }

        do {
            // 1. Generate a cryptographic nonce and store the raw value for Firebase.
            let nonce = randomNonceString()
            currentNonce = nonce

            // 2. Present the native Apple sign-in sheet and await the result.
            let authorization = try await withCheckedThrowingContinuation { continuation in
                appleSignInContinuation = continuation

                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.fullName, .email]
                request.nonce = sha256(nonce)   // hashed nonce sent to Apple

                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.performRequests()
            }

            // 3. Exchange the Apple credential for a Firebase credential.
            guard
                let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = appleCredential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let rawNonce = currentNonce
            else {
                throw AuthError.invalidCredential
            }

            let credential = OAuthProvider.credential(
                providerID: .apple,
                idToken: idToken,
                rawNonce: rawNonce
            )
            try await Auth.auth().signIn(with: credential)

        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Sign In with Google
    //
    // Uncomment this entire method once you add the GoogleSignIn-iOS SPM package
    // and un-comment `import GoogleSignIn` at the top of this file.

    func signInWithGoogle() async {
        isLoading = true
        authError = nil
        defer { isLoading = false }

        #if canImport(UIKit)
        // ── Uncomment block below after adding GoogleSignIn-iOS package ──
        do {
            guard
                let clientID = FirebaseApp.app()?.options.clientID,
                let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                let rootVC = windowScene.windows.first?.rootViewController
            else {
                throw AuthError.presentationContextMissing
            }

            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.invalidCredential
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            try await Auth.auth().signIn(with: credential)
        } catch {
            authError = error.localizedDescription
        }
        
        authError = "Add the GoogleSignIn-iOS SPM package to enable Google sign-in."
        #else
        authError = "Google Sign-In is not supported on this platform."
        #endif
    }

    // MARK: - Email / Password — Sign In

    func signIn(email: String, password: String) async {
        isLoading = true
        authError = nil
        defer { isLoading = false }

        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Email / Password — Create Account

    func createAccount(email: String, password: String, displayName: String) async {
        isLoading = true
        authError = nil
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let changeRequest = result.user.createProfileChangeRequest()
            changeRequest.displayName = displayName
            try await changeRequest.commitChanges()
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Anonymous sign-in (guest / "set up manually" flow)

    func signInAnonymously() async {
        isLoading = true
        authError = nil
        defer { isLoading = false }
        do {
            try await Auth.auth().signInAnonymously()
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Profile counter updates (debounced Firestore write)

    private var profileUpdateWorkItem: DispatchWorkItem?

    func incrementDistanceKm(by km: Double) {
        userProfile?.totalDistanceKm += km
        scheduleProfileFlush()
    }

    /// Call when a brand-new city (totalSessions == 1) is first recorded.
    func incrementCitiesExplored() {
        userProfile?.totalCitiesExplored += 1
        scheduleProfileFlush()
    }

    func incrementCitiesExplored(by count: Int) {
        guard count > 0 else { return }
        userProfile?.totalCitiesExplored += count
        scheduleProfileFlush()
    }

    /// Resets in-memory profile counters to zero without syncing to Firestore.
    /// Called after clearing all local data.
    func resetLocalStats() {
        userProfile?.totalCitiesExplored = 0
        userProfile?.totalDistanceKm     = 0
        profileUpdateWorkItem?.cancel()
        profileUpdateWorkItem = nil
    }

    /// Debounce: coalesce rapid counter ticks into a single Firestore write (max 1 per 5 s).
    private func scheduleProfileFlush() {
        profileUpdateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let profile = self.userProfile else { return }
                try? await self.userService.update(profile)
            }
        }
        profileUpdateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    // MARK: - Sign Out

    func signOut() {
        if isGuest {
            isGuest = false
            userProfile = nil
            UserDefaults.standard.set(false, forKey: Self.guestKey)
            return
        }
        do {
            try Auth.auth().signOut()
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Convenience

    var isAuthenticated: Bool { firebaseUser != nil || isGuest }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthViewModel: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(returning: authorization)
            appleSignInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
        }
    }
}

// MARK: - Private helpers

private extension AuthViewModel {

    enum AuthError: LocalizedError {
        case invalidCredential
        case presentationContextMissing

        var errorDescription: String? {
            switch self {
            case .invalidCredential:          return "Invalid credential received from provider."
            case .presentationContextMissing: return "Could not find a window to present sign-in."
            }
        }
    }

    /// Cryptographically secure random string for the Apple sign-in nonce.
    func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms) == errSecSuccess
            else { continue }
            for byte in randoms {
                guard remaining > 0 else { break }
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    /// SHA-256 hash of the nonce, sent to Apple so Firebase can verify it.
    func sha256(_ input: String) -> String {
        SHA256
            .hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
