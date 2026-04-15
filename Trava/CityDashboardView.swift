//  CityDashboardView.swift
//  Trava
//
//  Rebuilt from Stitch HTML (dashboard.html) with exact spacing, font sizes,
//  corner radii, colors, and component structure.
//
//  Tailwind → pt values used throughout:
//    text-[10px]=10  text-xs=12  text-sm=14  text-lg=18  text-2xl=24
//    text-3xl=30  text-4xl=36  text-5xl=48  text-6xl=60
//    rounded-xl=12  rounded-lg=8  rounded-full=9999
//    p-6=24  p-8=32  px-3=12  px-4=16  py-1=4  py-2=8
//    gap-6=24  gap-16=64  mt-6=24  mt-24=96  mb-4=16  mb-6=24

import SwiftUI
import UIKit

struct CityDashboardView: View {
    @Binding var selectedTab: AppTab
    var city: City? = nil   // injected when navigating from city list
    @EnvironmentObject var cityService: CityService
    @EnvironmentObject var trackService: TrackService
    @EnvironmentObject var auth: AuthViewModel
    @State private var showAddCity = false

    @AppStorage(DistanceUnit.storageKey) private var distanceUnitRaw: String = DistanceUnit.km.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }
    private var totalDistanceKm: Double {
        trackService.localTracks.reduce(0) { $0 + $1.distanceKm }
    }

    // Share state
    @State private var isRendering = false
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var shareError: String?

    // City boundary hero card
    @State private var heroImage: UIImage?
    @State private var heroLoading = false

    private let renderer = CitySnapshotRenderer()

    // Bar chart data: (primaryOpacity, heightFraction)
    private let chartBars: [(Double, Double)] = [
        (0.20, 0.20), (0.40, 0.35), (0.60, 0.55), (1.00, 0.85),
        (0.70, 0.60), (0.30, 0.25), (0.50, 0.45)
    ]

    private var effectiveCity: City? { city ?? cityService.cities.first }

    var body: some View {
        // ── Scrollable content (nav + tab bar live in ContentView's shell) ──
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header (mb-12 = 48pt) ─────────────────────
                headerSection
                    .padding(.bottom, 48)

                // ── Bento grid (gap-6 = 24pt stacked) ──────────
                VStack(spacing: 24) {
                    featuredCityCard
                    statsCard
                    cityCard(
                        name: "San Francisco",
                        percent: 45,
                        url: "https://lh3.googleusercontent.com/aida-public/AB6AXuCeqiPK2x2RSeR6aBhC5feEOmAzsToEsr9snmN0uepfpsbTYQbelD37DtxmVBAPfhbeWsiOPR-RN1MBiR951aUikZJu0FdTXYUSJIB21R9wECxC_UgT0fWU05TL9ONmuBBbFHzF0cdeiLRdQWalKQSbtIbPDHKerlciwNlK_UjLDBsqJPDqXX-2ntWLzU3ipjBpWWg9fICf3Aad1T8WNqkeRrLK1i-3mHlfLrrpYES2WPZ4XP6KRR-C9U5l0PmUNANAHDMFoDMFqHfT"
                    )
                    cityCard(
                        name: "Berlin",
                        percent: 62,
                        url: "https://lh3.googleusercontent.com/aida-public/AB6AXuDN2QxvjQSXj-nOMFVFcHZxBsS8EwVHXMOT5n6_Jgt-uL0bo0YO7tX8MhIc2I98gROTl05PQ70wnm_zYLhWOFUFFy8ubwauZyFTvmqOtPMQYJDEebjYZoxUSX13z8acIO3FdYG1fBn-Sv4jqTXsZNrEcKgHl2f2t7cExc1_ekwIVbFK7O_XJQtdIYkeJr1H3BzYgiD_Zjo-wLNv-3H1PJVXkUyDxs5q5sveUmI-SQkUJmZ9F7zhzn2pvg0GkZrnngBiKNUBXoXt9iBP"
                    )
                    expandNetworkCard
                }

                // ── Secondary section (mt-24 = 96pt) ───────────
                VStack(alignment: .leading, spacing: 0) {
                    recentDiscoverySection
                        .padding(.bottom, 64)
                    precisionHeatmapSection
                }
                .padding(.top, 96)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)   // px-6
            .padding(.top, 32)          // pt-8
            .padding(.bottom, 32)       // breathing room above tab bar safe area
        }
        .background(Color.dsBackground.ignoresSafeArea())
        .onAppear {
            if let userId = auth.currentUserId {
                Task { await cityService.refresh(userId: userId) }
            }
            Task { await loadHeroImage() }
        }
        .onChange(of: effectiveCity?.cityId) { _, _ in
            heroImage = nil
            Task { await loadHeroImage() }
        }
        // ── FAB ──────────────────────────────────────────────────────────
        .overlay(alignment: .bottomTrailing) {
            Button { showAddCity = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Color(hex: "#002e69"))
                    .frame(width: 56, height: 56)
                    .background(LinearGradient.primaryCTA)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 4)
            }
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showAddCity) {
            AddManageCityView(selectedTab: $selectedTab)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShareSheet) {
            if let img = shareImage {
                ActivityViewController(activityItems: [img, shareCaption])
            }
        }
        .alert("Share Failed", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
    }

    private var shareCaption: String {
        "Explored \(effectiveCity?.cityName ?? "the city") on Trava 🗺️"
    }

    // MARK: - Hero card rendering

    private func loadHeroImage() async {
        guard let target = effectiveCity, heroImage == nil, !heroLoading else { return }
        heroLoading = true
        defer { heroLoading = false }

        let name    = target.cityName
        let country = target.country
        let coords  = target.coordinates
        // Use a wide hero size; actual display width is ~screen width.
        let size    = CGSize(width: 750, height: 500)

        let boundary = await OSMService.shared.fetchCityBoundary(cityName: name, country: country)
        heroImage = await Task.detached(priority: .userInitiated) {
            if let boundary {
                return CityCardRenderer.render(boundary: boundary, trackCoords: coords, size: size)
            } else {
                return CityCardRenderer.renderPlaceholder(cityName: name, size: size)
            }
        }.value
    }

    private func renderAndShare() {
        guard let targetCity = effectiveCity else { return }
        isRendering = true
        Task {
            do {
                let userId = auth.currentUserId ?? UserProfile.guestUserId
                let allTracks = try await trackService.loadLocalTracks(userId: userId)
                let cityTracks = allTracks.filter { $0.cityName == targetCity.cityName }
                let image = try await renderer.render(city: targetCity, tracks: cityTracks)
                shareImage = image
                showShareSheet = true
            } catch {
                shareError = error.localizedDescription
            }
            isRendering = false
        }
    }

    // MARK: - Header
    // h1: font-headline text-5xl(48) font-extrabold tracking-tighter leading-none mb-4
    // p:  font-label text-on-surface-variant text-lg(18) leading-relaxed

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Global \n Footprint" — "Footprint" in primary
            VStack(alignment: .leading, spacing: -4) {
                Text("Global")
                    .font(.custom("PlusJakartaSans-ExtraBold", size: 48))
                    .foregroundColor(Color.dsOnSurface)
                Text("Footprint")
                    .font(.custom("PlusJakartaSans-ExtraBold", size: 48))
                    .foregroundColor(Color.dsPrimary)
            }
            .tracking(-2.4)         // tracking-tighter: -0.05em × 48 = -2.4
            .lineSpacing(0)
            .padding(.bottom, 16)   // mb-4

            Text("Tracking architectural discovery across major metropolitan hubs. Precision data for the modern urbanist.")
                .font(.custom("Inter-Regular", size: 18))   // text-lg
                .foregroundColor(Color.dsOnSurfaceVariant)
                .lineSpacing(7)     // leading-relaxed ≈ 1.625 × 18 ≈ 29pt line height → ~7pt extra
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Featured City Card (top city or Tokyo fallback)
    // relative overflow-hidden rounded-xl(12) bg-surface-container-low h-[400px]
    // Content: absolute bottom p-8, flex justify-between items-end

    private var featuredCityCard: some View {
        let name    = effectiveCity?.cityName ?? "Tokyo"
        let percent = effectiveCity.map { Int(($0.coveragePercent * 100).rounded()) } ?? 84
        let hasCoords = !(effectiveCity?.coordinates.isEmpty ?? true)
        return ZStack(alignment: .topTrailing) {
            tokyoCardBody(cityName: name, coveragePercent: percent)

            // Share button — top-right
            Button {
                renderAndShare()
            } label: {
                Group {
                    if isRendering {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Color.dsPrimary)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Color.dsPrimary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color.dsSurfaceContainerHigh.opacity(0.85))
                .clipShape(Circle())
            }
            .disabled(!hasCoords || isRendering)
            .padding(16)
        }
    }

    private func tokyoCardBody(cityName: String, coveragePercent: Int) -> some View {
        ZStack(alignment: .bottom) {
            // City boundary silhouette rendered by CityCardRenderer
            Group {
                if let img = heroImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Shimmer placeholder while loading
                    Color.dsSurfaceContainerLow
                        .overlay(
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color(hex: "#adc6ff").opacity(0.6))
                                .opacity(heroLoading ? 1 : 0)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // bg-gradient-to-t from-surface-container-lowest via-transparent opacity-80
            LinearGradient(
                stops: [
                    .init(color: Color.dsSurfaceContainerLowest.opacity(0.8), location: 0),
                    .init(color: Color.clear, location: 0.6),
                ],
                startPoint: .bottom,
                endPoint: .top
            )

            // p-8 content at bottom
            VStack(spacing: 0) {
                // flex justify-between items-end
                HStack(alignment: .bottom, spacing: 0) {
                    // Left: pill + city name
                    VStack(alignment: .leading, spacing: 0) {
                        // "Primary Hub" pill
                        // px-3(12) py-1(4) rounded-full bg-secondary(#ffb3ae)
                        // text-on-secondary(#68000b) text-[10px] font-bold tracking-widest uppercase mb-2(8)
                        Text("Primary Hub")
                            .font(.custom("Inter-Bold", size: 10))
                            .foregroundColor(Color(hex: "#68000b"))
                            .kerning(1.0)       // tracking-widest: 0.1em × 10 = 1.0
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)   // px-3
                            .padding(.vertical, 4)      // py-1
                            .background(Color.dsSecondary)  // bg-secondary = #ffb3ae
                            .clipShape(Capsule())            // rounded-full
                            .padding(.bottom, 8)             // mb-2

                        // City name — font-headline text-4xl(36) font-bold text-white
                        Text(cityName)
                            .font(.custom("PlusJakartaSans-Bold", size: 36))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 4)
                    }

                    Spacer()

                    // Right: "84%" + "Exploration Meta"
                    VStack(alignment: .trailing, spacing: 0) {
                        // font-headline text-6xl(60) font-black text-primary leading-none
                        HStack(alignment: .bottom, spacing: 0) {
                            Text("\(coveragePercent)")
                                .font(.custom("PlusJakartaSans-ExtraBold", size: 60))
                                .foregroundColor(Color.dsPrimary)
                                .lineLimit(1)
                            Text("%")
                                .font(.custom("PlusJakartaSans-ExtraBold", size: 24))  // text-2xl
                                .foregroundColor(Color.dsPrimary)
                                .padding(.bottom, 6)
                        }
                        // font-label text-on-surface-variant text-xs(12) uppercase tracking-widest mt-1(4)
                        Text("Exploration Meta")
                            .font(.custom("Inter-Regular", size: 12))
                            .foregroundColor(Color.dsOnSurfaceVariant)
                            .kerning(1.2)   // tracking-widest: 0.1em × 12 = 1.2
                            .textCase(.uppercase)
                            .padding(.top, 4)   // mt-1
                    }
                }

                // Progress bar — mt-6(24) h-1(4px) bg-surface-container-highest/30
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.dsSurfaceContainerHighest.opacity(0.3))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.dsPrimary)
                            .frame(width: geo.size.width * (Double(coveragePercent) / 100.0), height: 4)
                            .shadow(color: Color.dsPrimary.opacity(0.6), radius: 6)
                    }
                }
                .frame(height: 4)
                .padding(.top, 24)  // mt-6
            }
            .padding(32)    // p-8
        }
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: 400)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))  // rounded-xl
    }

    // MARK: - Stats Card
    // bg-surface-container-high(#2a2a2a) p-8(32) rounded-xl(12)

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Aggregate Data" — text-xs(12) font-bold text-primary tracking-[0.2em](2.4) uppercase mb-6(24)
            Text("Aggregate Data")
                .font(.custom("PlusJakartaSans-Bold", size: 12))
                .foregroundColor(Color.dsPrimary)
                .kerning(2.4)   // tracking-[0.2em]: 0.2 × 12
                .textCase(.uppercase)
                .padding(.bottom, 24)   // mb-6

            // space-y-8 = 32pt between each item
            VStack(alignment: .leading, spacing: 32) {
                // Total Cities
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Cities")
                        .font(.custom("Inter-Regular", size: 14))    // text-sm
                        .foregroundColor(Color.dsOnSurfaceVariant)
                    Text("\(cityService.cities.count)")
                        .font(.custom("PlusJakartaSans-Bold", size: 36))  // text-4xl
                        .foregroundColor(Color.dsOnSurface)
                }
                // Total Distance
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Distance")
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                    Text(distanceUnit.format(totalDistanceKm))
                        .font(.custom("PlusJakartaSans-Bold", size: 36))
                        .foregroundColor(Color.dsSecondary)  // text-secondary
                }
                // Quote — pt-4(16) border-t border-outline-variant/15
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.dsOutlineVariant.opacity(0.15))
                        .frame(height: 1)
                        .padding(.bottom, 16)   // pt-4 from border
                    Text("\"The city is not just a place in space, but a drama in time.\"")
                        .font(.custom("Inter-Regular", size: 12))    // text-xs
                        .foregroundColor(Color.dsOnSurfaceVariant)
                        .italic()
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(32)    // p-8
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurfaceContainerHigh)   // bg-surface-container-high = #2a2a2a
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - City Photo Card (SF / Berlin)
    // h-[300px] rounded-xl(12), grayscale image, p-6(24) flex justify-between

    private func cityCard(name: String, percent: Int, url: String) -> some View {
        ZStack(alignment: .bottom) {
            // Grayscale photo — grayscale class in HTML
            AsyncImage(url: URL(string: url)) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill().grayscale(1)
                } else {
                    Color.dsSurfaceContainerLow
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // bg-surface-container-lowest/40 overlay
            Color.dsSurfaceContainerLowest.opacity(0.4)

            // p-6 flex flex-col justify-between
            VStack(spacing: 0) {
                // Top-right: open_in_new button
                // w-10(40) h-10(40) rounded-full bg-surface-container-high/80
                HStack {
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16))
                            .foregroundColor(Color.dsPrimary)
                            .frame(width: 40, height: 40)
                            .background(Color.dsSurfaceContainerHigh.opacity(0.8))
                            .clipShape(Circle())
                    }
                }

                Spacer()

                // Bottom: city name + progress bar
                VStack(alignment: .leading, spacing: 8) {
                    // h2: text-2xl(24) font-bold text-white mb-2(8)
                    Text(name)
                        .font(.custom("PlusJakartaSans-Bold", size: 24))
                        .foregroundColor(.white)
                        .padding(.bottom, 0)

                    // flex items-center gap-4(16): progress bar + percentage
                    HStack(spacing: 16) {
                        // flex-1 h-0.5(2px) bg-white/20
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 2)
                                Rectangle()
                                    .fill(Color.dsPrimary)
                                    .frame(width: geo.size.width * (Double(percent) / 100.0), height: 2)
                            }
                        }
                        .frame(height: 2)

                        // font-label text-primary font-bold
                        Text("\(percent)%")
                            .font(.custom("Inter-Bold", size: 14))
                            .foregroundColor(Color.dsPrimary)
                    }
                }
            }
            .padding(24)    // p-6
        }
        .frame(height: 300)     // h-[300px]
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Expand Network Card
    // border-2 border-dashed border-outline-variant/30 rounded-xl p-8(32) h-[300px]

    private var expandNetworkCard: some View {
        VStack(spacing: 0) {
            // w-16(64) h-16(64) rounded-full bg-surface-container-high mb-4(16)
            ZStack {
                Circle()
                    .fill(Color.dsSurfaceContainerHigh)
                    .frame(width: 64, height: 64)
                Image(systemName: "plus")
                    .font(.system(size: 28))    // text-3xl ≈ 30px
                    .foregroundColor(Color.dsPrimary)
            }
            .padding(.bottom, 16)   // mb-4

            Text("Expand Network")
                .font(.custom("PlusJakartaSans-Bold", size: 16))
                .foregroundColor(Color.dsOnSurface)

            Text("Add a new metropolitan area to your tracking dashboard.")
                .font(.custom("Inter-Regular", size: 12))   // text-xs
                .foregroundColor(Color.dsOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)   // mt-2
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.dsOutlineVariant.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .onTapGesture { showAddCity = true }
    }

    // MARK: - Recent Discovery
    // space-y-6(24), h2: text-3xl(30) font-bold tracking-tight
    // card: p-6(24) rounded-xl(12) bg-surface-container-low flex gap-6(24)

    private var recentDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 24) {   // space-y-6
            Text("Recent Discovery")
                .font(.custom("PlusJakartaSans-Bold", size: 30))    // text-3xl
                .foregroundColor(Color.dsOnSurface)
                .tracking(-0.75)    // tracking-tight: -0.025em × 30 = -0.75

            HStack(alignment: .center, spacing: 24) {   // gap-6
                // w-20(80) h-20(80) rounded-lg(8)
                AsyncImage(url: URL(string: "https://lh3.googleusercontent.com/aida-public/AB6AXuABAX9i36rUatgn14aR4Z3DDSDnUZAT7dSrQf725DBIedghLy5UydrVxGcTLHOywNH1Ticdgkxk05jgdq8MNiMzFo3Vf3qXYQGmdzE5M7HRSVv3QkzOZsbdVQPaGvOX4v5u9LSvzluflt6pZK02dzU3x4A4_miQX51ep0I_sQ0lZPndqAme9sIjGW0hVVH7gwQO2m1XNFfw0AgP2OpWMkdXCr-1TzvDccq8wR4QKS-QknZbWIy6XTWe9d0S2javjHgCGBRxf0t7QXnj")) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Color.dsSurfaceContainerHigh
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))   // rounded-lg

                VStack(alignment: .leading, spacing: 0) {
                    // text-[10px] uppercase tracking-widest text-primary font-bold mb-1(4)
                    Text("Architecture Spot")
                        .font(.custom("Inter-Bold", size: 10))
                        .foregroundColor(Color.dsPrimary)
                        .kerning(1.0)
                        .textCase(.uppercase)
                        .padding(.bottom, 4)

                    // font-headline font-bold (16pt default)
                    Text("The Barbican Estate")
                        .font(.custom("PlusJakartaSans-Bold", size: 16))
                        .foregroundColor(Color.dsOnSurface)

                    // text-sm(14) text-on-surface-variant
                    Text("London, UK • Added 2h ago")
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(Color.dsOnSurfaceVariant)
                        .padding(.top, 2)
                }

                Spacer()
            }
            .padding(24)    // p-6
            .background(Color.dsSurfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Precision Heatmap
    // bg-surface-container-lowest(#0e0e0e) p-8(32) rounded-xl(12) overflow-hidden

    private var precisionHeatmapSection: some View {
        ZStack(alignment: .topTrailing) {
            // Decorative blur: absolute top-0 right-0 w-32(128) h-32(128) bg-secondary/5 -mr-16 -mt-16 blur-3xl
            Circle()
                .fill(Color.dsSecondary.opacity(0.05))
                .frame(width: 128, height: 128)
                .blur(radius: 40)
                .offset(x: 64, y: -64)

            VStack(alignment: .leading, spacing: 0) {
                // h2: text-3xl(30) font-bold tracking-tight mb-4(16)
                Text("Precision Heatmap")
                    .font(.custom("PlusJakartaSans-Bold", size: 30))
                    .foregroundColor(Color.dsOnSurface)
                    .tracking(-0.75)
                    .padding(.bottom, 16)   // mb-4

                // p: font-label text-on-surface-variant mb-6(24)
                Text("Your exploration activity peaked in Tokyo District 3 last week. 14 new structures identified.")
                    .font(.custom("Inter-Regular", size: 12))
                    .foregroundColor(Color.dsOnSurfaceVariant)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)   // mb-6

                // Bar chart: h-32(128) bg-surface-container-high(#2a2a2a) rounded-lg(8)
                // flex items-end gap-1(4) px-4(16) py-2(8)
                // Inner drawable height = 128 - 16 = 112pt
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<chartBars.count, id: \.self) { i in
                        UnevenRoundedRectangle(
                            topLeadingRadius: 2,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 2
                        )
                        .fill(Color.dsPrimary.opacity(chartBars[i].0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: 112 * chartBars[i].1)
                    }
                }
                .padding(.horizontal, 16)   // px-4
                .padding(.vertical, 8)      // py-2
                .frame(height: 128)         // h-32
                .background(Color.dsSurfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 8))   // rounded-lg
            }
        }
        .padding(32)    // p-8
        .background(Color.dsSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .clipped()
    }
}

// MARK: - Activity Sheet

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    // Wrap in a simulated shell so the preview matches the live layout
    ZStack {
        CityDashboardView(selectedTab: .constant(.dashboard))
            .environmentObject(CityService())
            .environmentObject(TrackService())
            .environmentObject(AuthViewModel())
    }
    .safeAreaInset(edge: .top,    spacing: 0) { DSNavBar() }
    .safeAreaInset(edge: .bottom, spacing: 0) { DSTabBar(selectedTab: .constant(.dashboard)) }
    .preferredColorScheme(.dark)
}
