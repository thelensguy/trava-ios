//  ContentView.swift
//  Trava

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var selectedTab: AppTab = .exploration
    @State private var showDrawer = false

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
            DSNavBar(onHamburger: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showDrawer = true
                }
            })
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DSTabBar(selectedTab: $selectedTab)
        }
        .overlay {
            if showDrawer {
                DrawerView(isPresented: $showDrawer, selectedTab: $selectedTab)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showDrawer)
    }
}

// MARK: - Slide-out Drawer

private struct DrawerView: View {
    @Binding var isPresented: Bool
    @Binding var selectedTab: AppTab
    @EnvironmentObject var auth: AuthViewModel

    @State private var showImport    = false
    @State private var showOnboarding = false
    @State private var panelVisible  = false

    private var isGuest: Bool { auth.currentUserId == UserProfile.guestUserId }

    private let drawerWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim overlay — tap to dismiss
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Drawer panel
            drawerPanel
                .frame(width: drawerWidth)
                .offset(x: panelVisible ? 0 : -drawerWidth)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                panelVisible = true
            }
        }
        .sheet(isPresented: $showImport) {
            ImportView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingConnectMapView { Task { await auth.signInAnonymously() } }
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            panelVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            isPresented = false
        }
    }

    private func navigate(to tab: AppTab) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            selectedTab = tab
        }
    }

    // MARK: - Panel content

    private var drawerPanel: some View {
        ZStack {
            // Glassmorphism background
            Rectangle()
                .fill(.ultraThinMaterial)
            Color.dsSurfaceContainerLow.opacity(0.92)
        }
        .ignoresSafeArea()
        .overlay(panelContent, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 32, x: 4, y: 0)
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── User identity ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.dsSurfaceContainerHigh)
                        .frame(width: 56, height: 56)
                    Image(systemName: "person.fill")
                        .font(.system(size: 24))
                        .foregroundColor(Color.dsPrimary)
                }

                Text(auth.userProfile?.displayName ?? "Explorer")
                    .font(.custom("PlusJakartaSans-Bold", size: 18))
                    .foregroundColor(Color.dsOnSurface)
                    .padding(.top, 4)

                Text("Explorer")
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(Color.dsOnSurfaceVariant)
            }
            .padding(.top, 64)   // below status bar
            .padding(.horizontal, 24)
            .padding(.bottom, 32)

            // Divider
            Rectangle()
                .fill(Color.dsOutlineVariant.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            // ── Menu items ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                drawerItem(icon: "map.fill",        label: "Explore")     { navigate(to: .exploration) }
                drawerItem(icon: "square.grid.2x2", label: "My Cities")   { navigate(to: .dashboard) }
                drawerItem(icon: "square.and.arrow.down", label: "Import") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showImport = true
                    }
                }
                drawerItem(icon: "gearshape",       label: "Settings")    { navigate(to: .settings) }
            }
            .padding(.horizontal, 12)

            Spacer()

            // ── Footer ────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                if isGuest {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showOnboarding = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 14))
                            Text("Sign in to sync")
                                .font(.custom("Inter-Medium", size: 13))
                        }
                        .foregroundColor(Color.dsPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.dsPrimary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal, 12)
                }

                Text("v\(appVersion)")
                    .font(.custom("Inter-Regular", size: 11))
                    .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.5))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
        }
    }

    private func drawerItem(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color.dsPrimary)
                    .frame(width: 24)
                Text(label)
                    .font(.custom("Inter-Medium", size: 15))
                    .foregroundColor(Color.dsOnSurface)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthViewModel())
}
