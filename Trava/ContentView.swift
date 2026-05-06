//  ContentView.swift
//  Trava
//
//  Root view — authentication gate and persistent tab shell.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var auth:            AuthViewModel
    @EnvironmentObject var cityService:     CityService
    @EnvironmentObject var trackService:    TrackService
    @EnvironmentObject var locationManager: LocationManager
    @State private var selectedTab: AppTab = .exploration
    @State private var showCitiesImport = false

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

    private var mainShell: some View {
        ZStack {
            // Cities tab — wrapped in NavigationStack for city detail push
            NavigationStack {
                AddManageCityView(selectedTab: $selectedTab)
                    .toolbarVisibility(.hidden, for: .navigationBar)
            }
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
            DSNavBar(
                trailing: selectedTab == .dashboard ? AnyView(importButton) : AnyView(EmptyView()),
                isPassiveTracking: !locationManager.isPassiveTrackingPaused
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DSTabBar(selectedTab: $selectedTab)
        }
        .sheet(isPresented: $showCitiesImport) {
            ImportView()
                .environmentObject(trackService)
                .environmentObject(cityService)
                .environmentObject(auth)
        }
    }

    private var importButton: some View {
        Button {
            showCitiesImport = true
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color.dsPrimary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthViewModel())
}
