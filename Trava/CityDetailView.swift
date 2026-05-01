//  CityDetailView.swift
//  Trava
//
//  City detail screen pushed from the Cities list via NavigationLink.
//  Layout: full-width OSM boundary hero (top 40%), city name + country
//  overlaid, stats row, gradient share button, chronological track list.

import SwiftUI
import UIKit
import CoreLocation

struct CityDetailView: View {
    let city: City

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var trackService: TrackService
    @EnvironmentObject var auth:         AuthViewModel

    @AppStorage(DistanceUnit.storageKey) private var distanceUnitRaw: String = DistanceUnit.km.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }

    @State private var tracks:     [ExplorationTrack] = []
    @State private var heroImage:  UIImage?
    @State private var heroLoading = false

    @State private var isRendering  = false
    @State private var shareImage:  UIImage?
    @State private var showShare    = false
    @State private var shareError:  String?

    private let renderer = CitySnapshotRenderer()

    private var coveragePercent: Int { Int((city.coveragePercent * 100).rounded()) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                heroSection
                contentSection
            }
        }
        .background(Color.dsBackground.ignoresSafeArea())
        .onAppear { Task { await loadData() } }
        .sheet(isPresented: $showShare) {
            if let img = shareImage {
                ActivityView(activityItems: [img, "Explored \(city.cityName) on Trava 🗺️"])
            }
        }
        .alert("Share Failed", isPresented: Binding(
            get:  { shareError != nil },
            set:  { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
    }

    // MARK: - Hero (full width, 40% screen height via GeometryReader)

    private var heroSection: some View {
        GeometryReader { proxy in
            heroContent(width: proxy.size.width)
        }
        .frame(maxWidth: .infinity)
        .frame(height: (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 844) * 0.40)
    }

    private func heroContent(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // City boundary image
            Group {
                if let img = heroImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.dsSurfaceContainerLow
                        .overlay(
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color.dsPrimary.opacity(0.6))
                                .opacity(heroLoading ? 1 : 0)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Scrim — bottom → transparent
            LinearGradient(
                stops: [
                    .init(color: Color.dsBackground.opacity(0.92), location: 0),
                    .init(color: Color.clear,                      location: 0.65),
                ],
                startPoint: .bottom,
                endPoint:   .top
            )

            // City name + country at bottom-left
            VStack(alignment: .leading, spacing: 4) {
                Text(city.country.uppercased())
                    .font(.custom("Inter-Medium", size: 11))
                    .foregroundColor(Color.dsOnSurfaceVariant)
                    .kerning(1.5)
                Text(city.cityName)
                    .font(.custom("PlusJakartaSans-Bold", size: 32))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Back button — top-left
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.dsOnSurface)
                    .frame(width: 36, height: 36)
                    .background(Color.dsSurfaceContainerHigh.opacity(0.85))
                    .clipShape(Circle())
            }
            .padding(16)
        }
    }

    // MARK: - Content (stats + share + tracks)

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 24) {

            // Stats row
            statsRow

            // Share button — gradient style
            shareButton

            // Track list or empty state
            if tracks.isEmpty {
                emptyTrackState
            } else {
                trackList
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    // MARK: - Stats Row (3 equal columns via LazyVGrid)

    private let statsColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 0),
    ]

    private var statsRow: some View {
        LazyVGrid(columns: statsColumns, spacing: 12) {
            statChip(value: distanceUnit.format(city.totalDistanceKm), label: "Distance", icon: "figure.walk")
            statChip(value: "\(city.totalSessions)",                   label: "Sessions", icon: "stopwatch")
            statChip(value: "\(coveragePercent)%",                     label: "Coverage", icon: "map")
        }
    }

    private func statChip(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color.dsPrimary)
            Text(value)
                .font(.custom("PlusJakartaSans-Bold", size: 17))
                .foregroundColor(Color.dsOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(Color.dsOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.dsSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    // MARK: - Share Button

    private var shareButton: some View {
        Button { renderAndShare() } label: {
            HStack(spacing: 8) {
                if isRendering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                }
                Text(isRendering ? "Generating…" : "Share City Map")
                    .font(.dsLabelLg())
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(LinearGradient.primaryCTA.opacity(isRendering ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .disabled(isRendering)
    }

    // MARK: - Track List

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.custom("PlusJakartaSans-Bold", size: 14))
                .foregroundColor(Color.dsPrimary)
                .kerning(1.8)
                .textCase(.uppercase)

            ForEach(tracks) { track in
                trackRow(track)
            }
        }
    }

    private func trackRow(_ track: ExplorationTrack) -> some View {
        let incomplete = isIncomplete(track)

        return HStack(spacing: 14) {
            // Date badge
            VStack(spacing: 1) {
                Text(track.startedAt, format: .dateTime.day())
                    .font(.custom("PlusJakartaSans-Bold", size: 20))
                    .foregroundColor(incomplete ? Color.dsOnSurfaceVariant.opacity(0.5) : Color.dsOnSurface)
                Text(track.startedAt, format: .dateTime.month(.abbreviated))
                    .font(.custom("Inter-Regular", size: 10))
                    .foregroundColor(Color.dsOnSurfaceVariant.opacity(incomplete ? 0.4 : 1))
                    .textCase(.uppercase)
                    .kerning(0.5)
            }
            .frame(width: 44)
            .padding(.vertical, 10)
            .background(Color.dsSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))

            if incomplete {
                Text("Incomplete")
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.45))
                    .italic()
            } else {
                // Distance + duration
                VStack(alignment: .leading, spacing: 3) {
                    Text(distanceUnit.format(track.distanceKm))
                        .font(.custom("PlusJakartaSans-Bold", size: 15))
                        .foregroundColor(Color.dsOnSurface)
                    Text(durationLabel(for: track))
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                }
            }

            Spacer()

            // Sync status indicator
            Image(systemName: track.isSynced ? "checkmark.icloud" : "icloud.slash")
                .font(.system(size: 13))
                .foregroundColor(
                    track.isSynced
                        ? Color.dsPrimary.opacity(0.55)
                        : Color.dsOnSurfaceVariant.opacity(0.35)
                )
        }
        .padding(14)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    // MARK: - Empty State

    private var emptyTrackState: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.walk.circle")
                .font(.system(size: 44))
                .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.3))
            Text("No sessions recorded")
                .font(.custom("PlusJakartaSans-Bold", size: 17))
                .foregroundColor(Color.dsOnSurface)
            Text("Start exploring \(city.cityName) to log your first session")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(Color.dsOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Helpers

    private func durationLabel(for track: ExplorationTrack) -> String {
        guard let end = track.endedAt else { return "In progress" }
        let secs = Int(end.timeIntervalSince(track.startedAt))
        guard secs >= 60 else { return "< 1 min" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m) min"
    }

    /// True when the track has no meaningful data — distance is 0 and
    /// duration is under 10 seconds. These are GPS cold-start artefacts.
    private func isIncomplete(_ track: ExplorationTrack) -> Bool {
        let duration = track.endedAt.map { $0.timeIntervalSince(track.startedAt) } ?? 0
        return track.distanceKm == 0 && duration < 10
    }

    private func loadData() async {
        // Hero image
        if heroImage == nil && !heroLoading {
            heroLoading = true
            defer { heroLoading = false }   // always clears spinner, even on early return

            let name       = city.cityName
            let country    = city.country
            let adminArea  = city.administrativeArea
            let coords     = city.coordinates
            let size       = CGSize(width: 750, height: 500)
            let centerCoord = coords.first.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }

            print("[CityDetail] loadData — city='\(name)' country='\(country)' coords=\(coords.count)")

            let boundary = await OSMService.shared.fetchCityBoundary(
                cityName:           name,
                country:            country,
                administrativeArea: adminArea.isEmpty ? nil : adminArea,
                coordinates:        centerCoord
            )
            print("[CityDetail] boundary: \(boundary == nil ? "nil" : "\(boundary!.count) pts")")

            heroImage = await Task.detached(priority: .userInitiated) {
                if let boundary {
                    print("[CityDetail] rendering with boundary (\(boundary.count) pts)")
                    return CityCardRenderer.render(boundary: boundary, trackCoords: coords, size: size)
                } else {
                    print("[CityDetail] rendering placeholder for '\(name)'")
                    return CityCardRenderer.renderPlaceholder(cityName: name, size: size)
                }
            }.value

            print("[CityDetail] heroImage: \(heroImage == nil ? "nil — unexpected" : "set ✓")")
        }

        // Tracks for this city
        let userId = auth.currentUserId ?? UserProfile.guestUserId
        let all    = (try? await trackService.loadLocalTracks(userId: userId)) ?? []
        tracks     = all.filter { $0.cityName == city.cityName }
        print("[CityDetail] tracks for '\(city.cityName)': \(tracks.count), distanceKm values: \(tracks.map { $0.distanceKm })")
    }

    private func renderAndShare() {
        isRendering = true
        Task {
            do {
                let userId    = auth.currentUserId ?? UserProfile.guestUserId
                let allTracks = try await trackService.loadLocalTracks(userId: userId)
                let cityTracks = allTracks.filter { $0.cityName == city.cityName }
                let image = try await renderer.render(city: city, tracks: cityTracks)
                shareImage = image
                showShare  = true
            } catch {
                shareError = error.localizedDescription
            }
            isRendering = false
        }
    }
}

// MARK: - Activity Sheet

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        CityDetailView(city: City(
            userId:          "preview",
            cityName:        "Tokyo",
            country:         "Japan",
            totalDistanceKm: 12.4,
            totalSessions:   5,
            coveragePercent: 0.31
        ))
        .environmentObject(TrackService())
        .environmentObject(AuthViewModel())
    }
    .safeAreaInset(edge: .top,    spacing: 0) { DSNavBar() }
    .safeAreaInset(edge: .bottom, spacing: 0) { DSTabBar(selectedTab: .constant(.dashboard)) }
    .preferredColorScheme(.dark)
}
