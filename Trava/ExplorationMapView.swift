//  ExplorationMapView.swift
//  Trava
//
//  Full-screen map with:
//    • Real GPS tracks rendered as MKPolyline overlays (#adc6ff)
//    • Live recording path (dashed, thinner) while a session is active
//    • Heatmap toggle via HeatmapOverlay (MKTileOverlay)
//    • Start / Stop recording FAB integrated into map actions panel
//    • Centers on user's location on first load
//
//  Pixel-perfect UI preserved from Stitch exploration.html.
//
//  Tailwind → pt conversions:
//    h-16=64  h-14=56  top-20=80  bottom-28=112
//    px-6=24  pl-12=48  pr-4=16  p-1.5=6  p-4=16  p-6=24  py-2=8  py-3=12  py-4=16
//    gap-2=8  gap-3=12  gap-4=16  gap-8=32  mt-6=24  mb-1=4
//    px-5=20  py-2=8  w-10=40  h-10=40
//    rounded=4  rounded-lg=8  rounded-xl=12

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - TravaMapView  (UIKit platforms only)

#if canImport(UIKit)
import UIKit
import FirebaseAuth

/// Full-featured MKMapView wrapper:
///   • Completed track polylines (primary color, 4pt)
///   • Live recording path (primary color 60% opacity, 2pt dashed)
///   • Heatmap tile overlay when showHeatmap is true
///   • User location dot
struct TravaMapView: UIViewRepresentable {

    let completedTracks: [ExplorationTrack]
    let allTracks: [[CLLocationCoordinate2D]]   // pre-built for heatmap; changes on every refresh
    let currentPath: [CLLocationCoordinate2D]
    let showHeatmap: Bool
    let mapType: MKMapType
    let heatmapIntensity: Double
    @Binding var region: MKCoordinateRegion

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate               = context.coordinator
        map.setRegion(region, animated: false)
        map.overrideUserInterfaceStyle = .dark
        map.showsUserLocation      = true
        map.isZoomEnabled          = true
        map.isScrollEnabled        = true
        map.isPitchEnabled         = false
        map.mapType                = mapType
        map.pointOfInterestFilter  = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Apply map type change.
        if map.mapType != mapType { map.mapType = mapType }

        // Animate region when center or zoom level changes explicitly.
        let centerChanged =
            abs(map.region.center.latitude  - region.center.latitude)  > 0.0001 ||
            abs(map.region.center.longitude - region.center.longitude) > 0.0001
        let spanChanged =
            abs(map.region.span.latitudeDelta  - region.span.latitudeDelta)  > 0.001 ||
            abs(map.region.span.longitudeDelta - region.span.longitudeDelta) > 0.001
        if centerChanged || spanChanged {
            map.setRegion(region, animated: true)
        }
        context.coordinator.updateOverlays(
            map:              map,
            completedTracks:  completedTracks,
            allTracks:        allTracks,
            currentPath:      currentPath,
            showHeatmap:      showHeatmap,
            heatmapIntensity: heatmapIntensity
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        private var renderedTrackIds: Set<String> = []
        private var currentPolyline: MKPolyline?
        private var heatmapOverlay: HeatmapOverlay?
        private var lastHeatmapTrackCount = 0
        private var lastHeatmapIntensity: Double = 1.0

        func updateOverlays(
            map: MKMapView,
            completedTracks: [ExplorationTrack],
            allTracks: [[CLLocationCoordinate2D]],
            currentPath: [CLLocationCoordinate2D],
            showHeatmap: Bool,
            heatmapIntensity: Double = 1.0
        ) {
            if showHeatmap {
                // ── Heatmap mode: remove all polylines, show heatmap only ─────────
                let toRemove = map.overlays.filter { !($0 is HeatmapOverlay) }
                map.removeOverlays(toRemove)
                currentPolyline  = nil
                renderedTrackIds = []

                let trackCount = allTracks.count
                let needsRebuild = heatmapOverlay == nil
                    || trackCount       != lastHeatmapTrackCount
                    || heatmapIntensity != lastHeatmapIntensity

                if needsRebuild {
                    let savedRegion = map.region
                    if let old = heatmapOverlay {
                        map.removeOverlay(old)
                        heatmapOverlay = nil
                    }
                    let overlay = HeatmapOverlay(tracks: allTracks, intensity: heatmapIntensity)
                    heatmapOverlay        = overlay
                    lastHeatmapTrackCount = trackCount
                    lastHeatmapIntensity  = heatmapIntensity
                    map.addOverlay(overlay, level: .aboveLabels)
                    map.setRegion(savedRegion, animated: false)
                }
            } else {
                // ── Paths mode: remove heatmap, show polylines only ───────────────
                if let h = heatmapOverlay {
                    map.removeOverlay(h)
                    heatmapOverlay        = nil
                    lastHeatmapTrackCount = 0   // force full rebuild when heatmap is re-enabled
                }

                // Detect filter changes: if any rendered ID left the current set,
                // remove all completed polylines and re-add the current set cleanly.
                let currentIds = Set(completedTracks.map { $0.trackId })
                if !renderedTrackIds.isSubset(of: currentIds) {
                    let toRemove = map.overlays.filter { ($0 as? MKPolyline)?.title?.hasPrefix("completed:") == true }
                    map.removeOverlays(toRemove)
                    renderedTrackIds = []
                }

                let newTracks = completedTracks.filter { !renderedTrackIds.contains($0.trackId) }
                for track in newTracks {
                    var coords = track.coordinates.map { $0.clCoordinate }
                    guard coords.count >= 2 else { continue }
                    let polyline       = MKPolyline(coordinates: &coords, count: coords.count)
                    polyline.title     = "completed:\(track.trackId)"
                    map.addOverlay(polyline, level: .aboveLabels)
                    renderedTrackIds.insert(track.trackId)
                }

                // Live recording path (dashed).
                if let old = currentPolyline { map.removeOverlay(old) }
                if currentPath.count >= 2 {
                    var pts        = currentPath
                    let polyline   = MKPolyline(coordinates: &pts, count: pts.count)
                    polyline.title = "recording"
                    map.addOverlay(polyline, level: .aboveLabels)
                    currentPolyline = polyline
                } else {
                    currentPolyline = nil
                }
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.lineCap  = .round
                renderer.lineJoin = .round
                if polyline.title == "recording" {
                    // Live path: thinner, semi-transparent, dashed
                    renderer.strokeColor  = UIColor(red: 0.678, green: 0.776, blue: 1.0, alpha: 0.7)
                    renderer.lineWidth    = 2.5
                    renderer.lineDashPattern = [NSNumber(value: 6), NSNumber(value: 4)]
                } else {
                    // Completed track: solid primary #adc6ff
                    renderer.strokeColor = UIColor(red: 0.678, green: 0.776, blue: 1.0, alpha: 1.0)
                    renderer.lineWidth   = 4.0
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // No-op — region binding handles centering.
        }
    }
}
#endif

// MARK: - ExplorationMapView

struct ExplorationMapView: View {

    @Binding var selectedTab: AppTab
    @EnvironmentObject var auth: AuthViewModel
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var trackService: TrackService
    @EnvironmentObject var cityService: CityService

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6598, longitude: 139.7004),
        span:   MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
    )
    @State private var searchText      = ""
    @State private var selectedFilter  = "All Time"
    @State private var isRecording      = false
    @State private var showHeatmap      = false
    @State private var showFocusCard    = true
    @State private var recordingStartTime: Date?
    @State private var hascenteredOnUser = false
    @State private var searchToast: String?

    /// Pre-built coordinate arrays for the heatmap overlay.
    /// Rebuilt on every refreshTracks() call so the heatmap always reflects
    /// the latest saved tracks (including passive background tracks).
    @State private var allTracks: [[CLLocationCoordinate2D]] = []

    @Environment(\.scenePhase) private var scenePhase

    // Settings-persisted map prefs
    @AppStorage("trava.mapTypeRaw")           private var mapTypeRaw: Int          = 0
    @AppStorage("trava.heatmapIntensity")     private var heatmapIntensity: Double = 1.0
    @AppStorage("trava.showHeatmapDefault")   private var showHeatmapDefault: Bool = false
    @AppStorage(DistanceUnit.storageKey)      private var distanceUnitRaw: String  = DistanceUnit.km.rawValue

    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }

    private let filters = ["All Time", "Last 30 Days", "Last 7 Days"]

    // Tracks filtered by the selected time pill.
    private var filteredTracks: [ExplorationTrack] {
        let now = Date()
        switch selectedFilter {
        case "Last 7 Days":
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
            return trackService.localTracks.filter { $0.startedAt >= cutoff }
        case "Last 30 Days":
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            return trackService.localTracks.filter { $0.startedAt >= cutoff }
        default:
            return trackService.localTracks
        }
    }

    private var mapType: MKMapType { MKMapType(rawValue: UInt(mapTypeRaw)) ?? .standard }

    var body: some View {
        ZStack(alignment: .top) {

            // ── Layer 0: Full-screen map ──────────────────────────────────
            #if canImport(UIKit)
            TravaMapView(
                completedTracks:  filteredTracks,
                allTracks:        allTracks,
                currentPath:      locationManager.currentSessionPoints,
                showHeatmap:      showHeatmap,
                mapType:          mapType,
                heatmapIntensity: heatmapIntensity,
                region:           $region
            )
            .ignoresSafeArea()
            #else
            Color.dsSurfaceContainerLow.ignoresSafeArea()
            #endif

            // ── Layer 1: Primary floating UI ──────────────────────────────
            VStack(spacing: 0) {
                topControls
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                Spacer()

                bottomSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 44)
            }

            // ── Layer 2: Floating map control pills (bottom-right) ─────────
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    floatingMapControls
                        .padding(.trailing, 20)
                        .padding(.bottom, 116)  // above recording button area
                }
            }

            // ── Layer 3: Search toast ──────────────────────────────────────
            if let toast = searchToast {
                VStack {
                    Text(toast)
                        .font(.custom("Inter-Medium", size: 14))
                        .foregroundColor(Color.dsOnSurface)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.dsSurfaceContainerHigh.opacity(0.95))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
                        .padding(.top, 88)  // below nav bar + search bar
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.25), value: searchToast)
            }
        }
        .onAppear {
            locationManager.requestPermissions()
            refreshTracks()
            centerOnUserIfNeeded()
            showHeatmap = showHeatmapDefault
        }
        .onReceive(NotificationCenter.default.publisher(
            for: PersistenceController.didResetNotification)
        ) { _ in
            isRecording        = false
            recordingStartTime = nil
            allTracks          = []
        }
        // Reload whenever user identity resolves (async Firebase auth catch-up).
        .onChange(of: auth.currentUserId) { _, userId in
            guard userId != nil else { return }
            refreshTracks()
        }
        // Rebuild allTracks whenever TravaApp populates localTracks — catches the
        // case where activateSession() runs after ExplorationMapView already appeared
        // and refreshTracks() returned a guest-user result for a signed-in user.
        .onChange(of: trackService.localTracks.count) { _, _ in
            refreshTracks()
        }
        .onChange(of: locationManager.currentLocation) { _, location in
            guard !hascenteredOnUser, let loc = location else { return }
            region = MKCoordinateRegion(
                center: loc.coordinate,
                span:   MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            hascenteredOnUser = true
        }
        .onChange(of: locationManager.currentSessionPoints.count) { _, _ in
            // Keep region on the user while recording.
            if isRecording, let loc = locationManager.currentLocation {
                region.center = loc.coordinate
            }
        }
        // Refresh when coming back to foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTracks() }
        }
        // Refresh when time filter changes so the heatmap data matches.
        .onChange(of: selectedFilter) { _, _ in
            refreshTracks()
        }
        // Periodic 30-second refresh — ensures passive background tracks
        // always surface on the map without needing an explicit action.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            refreshTracks()
        }
        // After "Clear all local data" completes, reload from CoreData (returns empty)
        // so the heatmap and polylines are immediately removed from the map.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppDataCleared"))) { _ in
            refreshTracks()
        }
    }

    // MARK: - Top Controls (space-y-4 = 16pt)

    private var topControls: some View {
        VStack(spacing: 16) {
            searchBar
            filterPill
        }
    }

    // MARK: - Search Bar
    // h-14(56) pl-12(48) bg-surface-container-high/80 backdrop-blur-xl rounded-xl(12) shadow-2xl

    private var searchBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(Color.dsOnSurfaceVariant)
                .frame(width: 48)

            TextField(
                "",
                text: $searchText,
                prompt: Text("Search any city or place...")
                    .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.6))
            )
            .font(.custom("Inter-Regular", size: 16))
            .foregroundColor(Color.dsOnSurface)
            .onSubmit { Task { await searchForPlace(query: searchText) } }

            Spacer().frame(width: 16)
        }
        .frame(height: 56)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.dsSurfaceContainerHigh.opacity(0.8)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 6)
    }

    // MARK: - Filter Pill
    // p-1.5(6) bg-surface-container-low/90 backdrop-blur-md rounded-xl(12)

    private var filterPill: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                ForEach(filters, id: \.self) { filter in
                    Button { selectedFilter = filter } label: {
                        Text(filter)
                            .font(.custom("Inter-Bold", size: 12))
                            .kerning(1.2)
                            .textCase(.uppercase)
                            .foregroundColor(
                                selectedFilter == filter
                                    ? Color(hex: "#002e69")
                                    : Color.dsOnSurfaceVariant
                            )
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(
                                selectedFilter == filter
                                    ? Color.dsPrimary
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(6)
            .background(
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Color.dsSurfaceContainerLow.opacity(0.9)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
            Spacer()
        }
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 16) {
            focusCardContainer
            mapActions
        }
    }

    // MARK: - Focus Card (collapsible)

    private var focusCardContainer: some View {
        VStack(spacing: 0) {
            if showFocusCard {
                focusCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Drag handle / toggle pill — always visible
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showFocusCard.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if !showFocusCard {
                        Text(locationManager.currentPlaceName)
                            .font(.custom("Inter-Bold", size: 11))
                            .foregroundColor(Color.dsOnSurfaceVariant)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Image(systemName: showFocusCard ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    ZStack {
                        Capsule().fill(.regularMaterial)
                        Capsule().fill(Color.dsSurfaceContainerHigh.opacity(0.7))
                    }
                )
            }
            .padding(.top, showFocusCard ? 8 : 0)
        }
    }

    // MARK: - Focus Card body
    // bg-surface-container-high/60 backdrop-blur-2xl p-6(24) rounded-xl(12) border-l-4 border-secondary/50

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top) {
                Text("Active Region")
                    .font(.custom("Inter-Bold", size: 10))
                    .foregroundColor(Color.dsSecondary)
                    .kerning(2.0)
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: "safari.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.dsSecondary)
            }

            Text(locationManager.currentPlaceName)
                .font(.custom("PlusJakartaSans-ExtraBold", size: 30))
                .foregroundColor(Color.dsOnSurface)
                .tracking(-1.5)
                .padding(.top, 16)
                .padding(.bottom, 4)

            HStack(alignment: .bottom, spacing: 32) {
                statColumn(label: "Distance",
                           value: String(format: "%.1f", distanceUnit.converted(totalDistanceKm)),
                           unit: distanceUnit.label.uppercased())
                statColumn(label: "Tracks",
                           value: "\(trackService.localTracks.count)",
                           unit: nil)
                Spacer()
            }
            .padding(.top, 24)
        }
        .padding(24)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.dsSurfaceContainerHigh.opacity(0.6)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.dsSecondary.opacity(0.5))
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 6)
    }

    private var totalDistanceKm: Double {
        trackService.localTracks.reduce(0) { $0 + $1.distanceKm }
    }

    @ViewBuilder
    private func statColumn(label: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("Inter-Regular", size: 10))
                .foregroundColor(Color.dsOnSurfaceVariant)
                .kerning(1.0)
                .textCase(.uppercase)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.custom("PlusJakartaSans-Bold", size: 24))
                    .foregroundColor(Color.dsOnSurface)
                if let unit {
                    Text(unit)
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                }
            }
        }
    }

    // MARK: - Recording Button (full-width, gradient)

    private var mapActions: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
                Text(isRecording ? "Stop Recording" : "Start Exploration")
                    .font(.custom("PlusJakartaSans-Bold", size: 12))
                    .foregroundColor(
                        isRecording ? Color(hex: "#68000b") : Color(hex: "#002e69")
                    )
                    .kerning(1.2)
                    .textCase(.uppercase)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                isRecording
                    ? AnyShapeStyle(Color.dsSecondary.opacity(0.9))
                    : AnyShapeStyle(LinearGradient.primaryCTA)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(
                color: (isRecording ? Color.dsSecondary : Color.dsPrimary).opacity(0.35),
                radius: 16, x: 0, y: 4
            )
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
    }

    // MARK: - Floating Map Control Pills (bottom-right, icon-only 44×44)

    private var floatingMapControls: some View {
        VStack(spacing: 8) {
            // LOCATE — centers on current GPS
            floatPill(icon: "location.fill", active: false) {
                if let loc = locationManager.currentLocation {
                    region = MKCoordinateRegion(
                        center: loc.coordinate,
                        span:   MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                }
            }

            // PATHS / HEATMAP toggle
            floatPill(icon: showHeatmap ? "map" : "flame", active: showHeatmap) {
                showHeatmap.toggle()
            }
        }
    }

    private func floatPill(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(active ? Color.dsSecondary : Color.dsPrimary)
                .frame(width: 44, height: 44)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: 10).fill(Color.dsSurfaceContainerHigh.opacity(0.85))
                    }
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Recording logic

    private func toggleRecording() async {
        if isRecording {
            // ── Stop ──
            let locations = locationManager.stopForegroundTracking()
            isRecording   = false

            guard !locations.isEmpty,
                  let userId = auth.currentUserId
            else { return }

            let coordinates = locations.map { Coordinate($0.coordinate) }
            let city        = await trackService.cityName(for: locations.first?.coordinate)
            let track       = ExplorationTrack(
                userId:      userId,
                coordinates: coordinates,
                startedAt:   locations.first?.timestamp ?? recordingStartTime ?? Date(),
                endedAt:     Date(),
                distanceKm:  ExplorationTrack.distance(from: locations),
                cityName:    city
            )
            recordingStartTime = nil

            try? await trackService.saveTrackLocally(track)
            trackService.localTracks.append(track)

            // Detect cities and upsert CityEntity records
            let savedCities = (try? await cityService.detectAndSaveCities(
                track: track, userId: userId
            )) ?? []
            await cityService.refresh(userId: userId)

            // Update profile counters (debounced Firestore write)
            auth.incrementDistanceKm(by: track.distanceKm)
            let newCityCount = savedCities.filter { $0.totalSessions == 1 }.count
            if newCityCount > 0 {
                auth.incrementCitiesExplored(by: newCityCount)
            }

            // Try to sync immediately (best-effort).
            await trackService.syncPendingTracks(userId: userId)

            // Force heatmap + polyline refresh with the new track included.
            refreshTracks()

        } else {
            // ── Start ──
            locationManager.requestPermissions()
            recordingStartTime = Date()
            locationManager.startForegroundTracking()
            isRecording = true
        }
    }

    // MARK: - Helpers

    /// Loads the latest tracks from CoreData, updates the service's localTracks,
    /// and rebuilds allTracks for the heatmap overlay.  Called on appear, foreground
    /// transitions, filter changes, and every 30 s.
    private func refreshTracks() {
        // Fall back to guestUserId when Firebase auth hasn't resolved yet so
        // allTracks is always populated from local CoreData on first load.
        let userId = auth.currentUserId ?? UserProfile.guestUserId
        Task {
            await trackService.refreshLocalTracks(userId: userId)
            // Rebuild allTracks from the (now up-to-date) filtered set so the
            // heatmap coordinator sees a changed count and forces a full tile rebuild.
            allTracks = filteredTracks.map { $0.coordinates.map { $0.clCoordinate } }
        }
    }

    private func searchForPlace(query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            guard let first = response.mapItems.first else {
                showToast("Location not found")
                return
            }
            region = response.boundingRegion
            showToast("Flying to \(first.name ?? q)…")
        } catch {
            showToast("Location not found")
        }
    }

    private func showToast(_ message: String, duration: Double = 2.0) {
        withAnimation { searchToast = message }
        Task {
            try? await Task.sleep(for: .seconds(duration))
            withAnimation { searchToast = nil }
        }
    }

    private func centerOnUserIfNeeded() {
        guard let loc = locationManager.currentLocation, !hascenteredOnUser else { return }
        region = MKCoordinateRegion(
            center: loc.coordinate,
            span:   MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        hascenteredOnUser = true
    }
}

#Preview {
    ZStack {
        ExplorationMapView(selectedTab: .constant(.exploration))
            .environmentObject(AuthViewModel())
            .environmentObject(LocationManager())
            .environmentObject(TrackService())
            .environmentObject(CityService())
    }
    .safeAreaInset(edge: .top,    spacing: 0) { DSNavBar() }
    .safeAreaInset(edge: .bottom, spacing: 0) { DSTabBar(selectedTab: .constant(.exploration)) }
    .preferredColorScheme(.dark)
}
