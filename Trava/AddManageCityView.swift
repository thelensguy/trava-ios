//  AddManageCityView.swift
//  Trava
//
//  Cities list screen: stats header, search filter, city cards with
//  OSM boundary thumbnails, NavigationLinks to CityDashboardView,
//  and empty state. Hosted inside ContentView's NavigationStack.

import SwiftUI

struct AddManageCityView: View {
    @Binding var selectedTab: AppTab
    @EnvironmentObject var cityService:  CityService
    @EnvironmentObject var trackService: TrackService
    @EnvironmentObject var auth:         AuthViewModel
    @AppStorage(DistanceUnit.storageKey) private var distanceUnitRaw: String = DistanceUnit.km.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }

    @State private var searchText = ""

    private var filteredCities: [City] {
        guard !searchText.isEmpty else { return cityService.cities }
        return cityService.cities.filter {
            $0.cityName.localizedCaseInsensitiveContains(searchText) ||
            $0.country.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var totalDistanceKm: Double {
        cityService.cities.reduce(0) { $0 + $1.totalDistanceKm }
    }

    private var totalTracks: Int {
        cityService.cities.reduce(0) { $0 + $1.totalSessions }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Stats row
                statsHeader
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 24)

                // Search / filter
                filterBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                // Cities or empty state
                if cityService.cities.isEmpty {
                    emptyState
                        .padding(.horizontal, 24)
                } else {
                    citiesSection
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color.dsBackground.ignoresSafeArea())
        .onAppear {
            if let userId = auth.currentUserId {
                Task { await cityService.refresh(userId: userId) }
            }
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 12) {
            statPill(value: "\(cityService.cities.count)", label: "Cities",
                     icon: "mappin.circle.fill")
            statPill(value: String(format: "%.0f", distanceUnit.converted(totalDistanceKm)),
                     label: distanceUnit.label,
                     icon: "figure.walk")
            statPill(value: "\(totalTracks)", label: "Tracks",
                     icon: "square.3.layers.3d")
        }
    }

    private func statPill(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Color.dsPrimary)
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
        .padding(.vertical, 14)
        .background(Color.dsSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundColor(Color.dsOnSurfaceVariant)
                .padding(.leading, 14)
                .padding(.trailing, 8)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Filter cities…")
                    .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.5))
            )
            .font(.custom("Inter-Regular", size: 15))
            .foregroundColor(Color.dsOnSurface)
            .padding(.vertical, 12)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.6))
                }
                .padding(.trailing, 12)
            }
        }
        .background(Color.dsSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Cities Section

    private var citiesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("My Cities")
                    .font(.custom("PlusJakartaSans-Bold", size: 20))
                    .foregroundColor(Color.dsOnSurface)
                Spacer()
                Text("\(filteredCities.count)")
                    .font(.custom("Inter-Regular", size: 12))
                    .foregroundColor(Color.dsOnSurfaceVariant)
            }

            if filteredCities.isEmpty && !searchText.isEmpty {
                Text("No cities match \"\(searchText)\"")
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(Color.dsOnSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(filteredCities) { city in
                    NavigationLink(destination: CityDetailView(city: city)) {
                        CityRowView(city: city)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 52))
                .foregroundColor(Color.dsOnSurfaceVariant.opacity(0.35))
                .padding(.bottom, 4)
            Text("No cities yet")
                .font(.custom("PlusJakartaSans-Bold", size: 20))
                .foregroundColor(Color.dsOnSurface)
            Text("Start exploring to see your cities here")
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(Color.dsOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

// MARK: - City Row with OSM Boundary Thumbnail

struct CityRowView: View {
    let city: City
    @AppStorage(DistanceUnit.storageKey) private var distanceUnitRaw: String = DistanceUnit.km.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }
    @State private var snapshot: UIImage?

    var body: some View {
        HStack(spacing: 16) {
            // Map thumbnail
            ZStack {
                Color.dsSurfaceContainerHighest
                if let img = snapshot {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(city.cityName)
                    .font(.custom("PlusJakartaSans-Bold", size: 16))
                    .foregroundColor(Color.dsOnSurface)
                Text("\(city.country) · \(city.totalSessions) session\(city.totalSessions == 1 ? "" : "s") · \(distanceUnit.format(city.totalDistanceKm))")
                    .font(.custom("Inter-Regular", size: 12))
                    .foregroundColor(Color.dsOnSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(Color.dsOnSurfaceVariant)
        }
        .padding(16)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await loadSnapshot() }
    }

    private func loadSnapshot() async {
        guard snapshot == nil else { return }
        let size     = CGSize(width: 128, height: 128)
        let name     = city.cityName
        let country  = city.country
        let coords   = city.coordinates
        let boundary = await OSMService.shared.fetchCityBoundary(cityName: name, country: country)
        snapshot = await Task.detached(priority: .userInitiated) {
            if let boundary {
                return CityCardRenderer.render(boundary: boundary, trackCoords: coords, size: size)
            } else {
                return CityCardRenderer.renderPlaceholder(cityName: name, size: size)
            }
        }.value
    }
}

#Preview {
    NavigationStack {
        AddManageCityView(selectedTab: .constant(.dashboard))
            .environmentObject(CityService())
            .environmentObject(TrackService())
            .environmentObject(AuthViewModel())
    }
    .safeAreaInset(edge: .top,    spacing: 0) { DSNavBar() }
    .safeAreaInset(edge: .bottom, spacing: 0) { DSTabBar(selectedTab: .constant(.dashboard)) }
    .preferredColorScheme(.dark)
}
