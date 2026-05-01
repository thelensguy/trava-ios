//  SettingsView.swift
//  Trava
//
//  Full settings screen: Tracking, Map, Data, Account sections.
//  All preferences are persisted via @AppStorage (UserDefaults).

import SwiftUI
import CoreData

struct SettingsView: View {
    @Binding var selectedTab: AppTab
    @EnvironmentObject var auth:            AuthViewModel
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var trackService:    TrackService
    @EnvironmentObject var cityService:     CityService

    // MARK: Tracking preferences
    @AppStorage("trava.trackingPrecision") private var precisionRaw: String  = TrackingPrecision.balanced.rawValue
    @AppStorage("trava.backgroundTracking") private var backgroundTracking: Bool = true
    @AppStorage("trava.pauseTracking")      private var pauseTracking: Bool       = false
    @AppStorage(DistanceUnit.storageKey)    private var distanceUnitRaw: String   = DistanceUnit.km.rawValue

    // MARK: Map preferences
    @AppStorage("trava.mapTypeRaw")          private var mapTypeRaw: Int         = 0
    @AppStorage("trava.showHeatmapDefault")  private var showHeatmapDefault: Bool = false
    @AppStorage("trava.heatmapIntensity")    private var heatmapIntensity: Double = 1.0

    // MARK: Local state
    @State private var totalTracks       = 0
    @State private var showClearConfirm  = false
    @State private var showClearSuccess  = false
    @State private var showOnboarding    = false

    private var precision: TrackingPrecision {
        TrackingPrecision(rawValue: precisionRaw) ?? .balanced
    }
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: distanceUnitRaw) ?? .km
    }
    private var totalDistanceKm: Double {
        trackService.localTracks.reduce(0) { $0 + $1.distanceKm }
    }
    private var isGuest: Bool { auth.currentUserId == UserProfile.guestUserId }

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Tracking")
                trackingSection

                sectionHeader("Map")
                mapSection

                sectionHeader("Data")
                dataSection

                sectionHeader("Account")
                accountSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color.dsSurface.ignoresSafeArea())
        .onAppear { loadStats() }
        .onChange(of: precisionRaw)      { _, _ in locationManager.applyPrecision(precision) }
        .onChange(of: backgroundTracking) { _, v  in locationManager.setBackgroundTracking(v) }
        .onChange(of: pauseTracking)      { _, v  in
            if v { locationManager.pausePassiveTracking() }
            else { locationManager.resumePassiveTracking() }
        }
        .confirmationDialog(
            "Delete all local data?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All Data", role: .destructive) { clearAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All tracks and cities stored on this device will be removed. This cannot be undone.")
        }
        .alert("Data Cleared", isPresented: $showClearSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All local data cleared successfully.")
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingConnectMapView { Task { await auth.signInAnonymously() } }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.custom("Inter-Bold", size: 11))
            .foregroundColor(Color.dsPrimary)
            .kerning(1.5)
            .padding(.horizontal, 4)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }

    // MARK: - Tracking Section

    private var trackingSection: some View {
        VStack(spacing: 1) {
            // Precision picker
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsLabel("Tracking Precision", icon: "scope")

                    HStack(spacing: 6) {
                        ForEach(TrackingPrecision.allCases, id: \.self) { p in
                            Button { precisionRaw = p.rawValue } label: {
                                Text(p.shortTitle)
                                    .font(.custom("Inter-Medium", size: 11))
                                    .foregroundColor(
                                        precision == p ? Color(hex: "#002e69") : Color.dsOnSurface
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        precision == p
                                            ? Color.dsPrimary
                                            : Color.dsSurfaceContainerHighest
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    Text(precision.subtitle)
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsToggle(
                label:    "Background Tracking",
                subtitle: "Continues recording while the app is in the background",
                icon:     "antenna.radiowaves.left.and.right",
                isOn:     $backgroundTracking
            )

            settingsToggle(
                label:    "Pause Tracking",
                subtitle: "Temporarily suspends all passive location tracking",
                icon:     "pause.circle",
                isOn:     $pauseTracking
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsLabel("Distance Unit", icon: "ruler")
                    HStack(spacing: 6) {
                        ForEach(DistanceUnit.allCases, id: \.self) { unit in
                            Button { distanceUnitRaw = unit.rawValue } label: {
                                Text(unit.displayName)
                                    .font(.custom("Inter-Medium", size: 11))
                                    .foregroundColor(
                                        distanceUnit == unit
                                            ? Color(hex: "#002e69") : Color.dsOnSurface
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        distanceUnit == unit
                                            ? Color.dsPrimary
                                            : Color.dsSurfaceContainerHighest
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Map Section

    private var mapSection: some View {
        VStack(spacing: 1) {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsLabel("Map Style", icon: "map")

                    HStack(spacing: 6) {
                        ForEach([("Standard", 0), ("Satellite", 1), ("Hybrid", 2)], id: \.1) { name, raw in
                            Button { mapTypeRaw = raw } label: {
                                Text(name)
                                    .font(.custom("Inter-Medium", size: 11))
                                    .foregroundColor(
                                        mapTypeRaw == raw ? Color(hex: "#002e69") : Color.dsOnSurface
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        mapTypeRaw == raw
                                            ? Color.dsPrimary
                                            : Color.dsSurfaceContainerHighest
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }

            settingsToggle(
                label:    "Show Heatmap by Default",
                subtitle: "Exploration view opens with heatmap already enabled",
                icon:     "flame",
                isOn:     $showHeatmapDefault
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        settingsLabel("Heatmap Intensity", icon: "slider.horizontal.3")
                        Spacer()
                        Text(intensityLabel)
                            .font(.custom("Inter-Medium", size: 12))
                            .foregroundColor(Color.dsPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.dsPrimary.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "minus")
                            .font(.system(size: 11))
                            .foregroundColor(Color.dsOnSurfaceVariant)
                        Slider(value: $heatmapIntensity, in: 0.5...2.0, step: 0.1)
                            .tint(Color.dsPrimary)
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundColor(Color.dsOnSurfaceVariant)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(spacing: 1) {
            settingsCard {
                HStack(spacing: 0) {
                    statItem("Tracks", value: "\(totalTracks)")
                    Rectangle()
                        .fill(Color.dsOutlineVariant.opacity(0.3))
                        .frame(width: 1, height: 36)
                    statItem("Distance", value: distanceUnit.format(totalDistanceKm))
                    Rectangle()
                        .fill(Color.dsOutlineVariant.opacity(0.3))
                        .frame(width: 1, height: 36)
                    statItem("Cities", value: "\(auth.userProfile?.totalCitiesExplored ?? 0)")
                }
            }

            settingsCard {
                Button { showClearConfirm = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash")
                            .font(.system(size: 15))
                            .foregroundColor(Color.dsError)
                            .frame(width: 22)
                        Text("Clear all local data")
                            .font(.custom("Inter-Medium", size: 14))
                            .foregroundColor(Color.dsError)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.dsOutlineVariant)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(spacing: 1) {
            // Display name row
            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.dsPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.userProfile?.displayName ?? "Explorer")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 15))
                            .foregroundColor(Color.dsOnSurface)
                        Text(isGuest ? "Guest · Not syncing" : "Signed in")
                            .font(.custom("Inter-Regular", size: 12))
                            .foregroundColor(Color.dsOnSurfaceVariant)
                    }
                    Spacer()
                }
            }

            if isGuest {
                settingsCard {
                    Button { showOnboarding = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 15))
                                .foregroundColor(Color.dsPrimary)
                                .frame(width: 22)
                            Text("Sign in to sync your data")
                                .font(.custom("Inter-Medium", size: 14))
                                .foregroundColor(Color.dsPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.dsOutlineVariant)
                        }
                    }
                }
            } else {
                settingsCard {
                    Button { auth.signOut() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 15))
                                .foregroundColor(Color.dsSecondary)
                                .frame(width: 22)
                            Text("Sign Out")
                                .font(.custom("Inter-Medium", size: 14))
                                .foregroundColor(Color.dsSecondary)
                            Spacer()
                        }
                    }
                }
            }

            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                        .frame(width: 22)
                    Text("Version")
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(Color.dsOnSurface)
                    Spacer()
                    Text(appVersion)
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Shared Builders

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsSurfaceContainerHigh)
    }

    private func settingsToggle(
        label:    String,
        subtitle: String,
        icon:     String,
        isOn:     Binding<Bool>
    ) -> some View {
        settingsCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(Color.dsPrimary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.custom("Inter-Medium", size: 14))
                        .foregroundColor(Color.dsOnSurface)
                    Text(subtitle)
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(Color.dsPrimary)
            }
        }
    }

    private func settingsLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Color.dsPrimary)
            Text(text)
                .font(.custom("Inter-Medium", size: 14))
                .foregroundColor(Color.dsOnSurface)
        }
    }

    private func statItem(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.custom("PlusJakartaSans-Bold", size: 20))
                .foregroundColor(Color.dsOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(Color.dsOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var intensityLabel: String {
        switch heatmapIntensity {
        case 0.5..<0.9:  return "Faint"
        case 0.9..<1.2:  return "Normal"
        case 1.2..<1.7:  return "Bright"
        default:         return "Max"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func loadStats() {
        guard let userId = auth.currentUserId else { return }
        Task {
            totalTracks = (try? await trackService.loadLocalTracks(userId: userId))?.count ?? 0
        }
    }

    private func clearAllData() {
        Task { @MainActor in
            let ctx = PersistenceController.shared.container.viewContext

            // 1. Batch-delete every entity type before resetting the store.
            //    Belt-and-suspenders: guarantees rows are gone even if resetStore
            //    hits a race on the WAL journal.
            for entityName in ["TrackEntity", "CityEntity", "CityBoundaryEntity"] {
                let fetchReq = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteReq = NSBatchDeleteRequest(fetchRequest: fetchReq)
                deleteReq.resultType = .resultTypeObjectIDs
                if let result  = try? ctx.execute(deleteReq) as? NSBatchDeleteResult,
                   let deleted = result.result as? [NSManagedObjectID], !deleted.isEmpty {
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: deleted],
                        into: [ctx]
                    )
                }
            }
            try? ctx.save()

            // 2. Destroy + recreate the SQLite store (clears WAL / SHM files too).
            PersistenceController.shared.resetStore()

            // 3. Reset ALL in-memory state directly — don't rely on the async
            //    notification chain which defers work via Task and can race with
            //    the success alert being dismissed.
            cityService.clearLocalState()
            trackService.localTracks              = []
            locationManager.currentSessionPoints  = []
            auth.resetLocalStats()

            // 4. Reset this view's stat counter.
            totalTracks = 0

            // 5. Tell living views (Cities list, Exploration map) to force-refresh
            //    to empty state.
            NotificationCenter.default.post(
                name: Notification.Name("AppDataCleared"), object: nil
            )

            // 6. Show success only after all of the above completes.
            showClearSuccess = true
        }
    }
}

#Preview {
    SettingsView(selectedTab: .constant(.settings))
        .environmentObject(AuthViewModel())
        .environmentObject(LocationManager())
        .environmentObject(TrackService())
        .environmentObject(CityService())
        .preferredColorScheme(.dark)
}
