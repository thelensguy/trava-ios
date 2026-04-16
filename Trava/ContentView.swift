//  ContentView.swift
//  Trava

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var selectedTab: AppTab = .exploration

    var body: some View {
        Group {
            if auth.isAuthenticated {
                mainShell
            } else {
                OnboardingConnectMapView {
                    Task { await auth.signInAnonymously() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Persistent shell

    /// All three tab views live simultaneously in a ZStack (mirroring
    /// UITabBarController). Only opacity + hit-testing change on tab switch,
    /// so DSNavBar and DSTabBar never remount and state is preserved
    /// (e.g. an active recording is not interrupted when the user browses
    /// to the dashboard and comes back).
    private var mainShell: some View {
        ZStack {
            // Tab content — all always alive, only the active one is visible
            CityDashboardView(selectedTab: $selectedTab)
                .opacity(selectedTab == .dashboard   ? 1 : 0)
                .allowsHitTesting(selectedTab == .dashboard)

            ExplorationMapView(selectedTab: $selectedTab)
                .opacity(selectedTab == .exploration ? 1 : 0)
                .allowsHitTesting(selectedTab == .exploration)

            SettingsView(selectedTab: $selectedTab)
                .opacity(selectedTab == .settings    ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            DSNavBar()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DSTabBar(selectedTab: $selectedTab)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthViewModel())
}
