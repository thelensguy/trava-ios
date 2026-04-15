//  ImportView.swift
//  Trava
//
//  Sheet for importing tracks from Apple Health or .gpx files.
//  Presented from AddManageCityView via an Import toolbar button.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Phase

private enum ImportPhase: Equatable {
    case idle
    case importing(processed: Int, total: Int)
    case done(tracks: Int, cities: Int)
    case failed(String)
}

// MARK: - GPX Document Picker

private struct GPXDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Accept the registered GPX type, XML, and generic data as fallbacks.
        var types: [UTType] = [.xml, .data]
        if let gpx = UTType(filenameExtension: "gpx") { types.insert(gpx, at: 0) }
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - ImportView

struct ImportView: View {

    @EnvironmentObject var trackService: TrackService
    @EnvironmentObject var cityService:  CityService
    @EnvironmentObject var auth:         AuthViewModel
    @Environment(\.dismiss) private var dismiss

    private let health    = HealthKitService.shared
    private let gpxParser = GPXParser()

    // Health
    @State private var healthStart    = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var healthEnd      = Date()
    @State private var workoutCount: Int? = nil

    // GPX
    @State private var showPicker  = false
    @State private var pickedURL: URL? = nil

    // Progress
    @State private var phase: ImportPhase = .idle

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.dsBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Spacer().frame(height: 64)

                    healthCard
                    gpxCard
                    statusSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }

            headerBar
        }
        .sheet(isPresented: $showPicker) {
            GPXDocumentPicker { url in pickedURL = url }
        }
        .onChange(of: pickedURL) { _, url in
            guard let url else { return }
            Task { await runGPXImport(url: url) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.dsOnSurface)
                    .frame(width: 34, height: 34)
                    .background(Color.dsSurfaceContainerHigh)
                    .clipShape(Circle())
            }

            Spacer()

            Text("IMPORT TRACKS")
                .font(.custom("PlusJakartaSans-SemiBold", size: 13))
                .foregroundColor(.dsOnSurface)
                .kerning(1.6)

            Spacer()

            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(
            Color.dsBackground.opacity(0.9)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Apple Health Card

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(
                icon: "heart.fill",
                iconTint: Color(hex: "#ff375f"),
                title: "Apple Health",
                subtitle: "Import walking & running routes",
                badge: !health.isAvailable ? "Unavailable" : nil
            )
            .padding(.bottom, 20)

            if health.isAvailable {
                dateRangePicker
                    .padding(.bottom, 16)

                workoutCountBadge
                    .padding(.bottom, 16)

                if isImporting {
                    busyRow("Importing…")
                } else {
                    Button {
                        Task { await runHealthImport() }
                    } label: {
                        Label("Import from Health", systemImage: "heart.text.square.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Text("HealthKit is not available on this device.")
                    .font(.dsBodyMd())
                    .foregroundColor(.dsOnSurfaceVariant)
            }
        }
        .padding(20)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    // MARK: - GPX Card

    private var gpxCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(
                icon: "doc.badge.arrow.up",
                iconTint: Color.dsPrimary,
                title: "GPX File",
                subtitle: "Import from Garmin, Strava, AllTrails…",
                badge: nil
            )
            .padding(.bottom, 20)

            // Selected file row
            if let url = pickedURL {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.dsPrimary)
                        .font(.system(size: 14))
                    Text(url.lastPathComponent)
                        .font(.dsLabelMd())
                        .foregroundColor(.dsOnSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { pickedURL = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.dsOutline)
                    }
                }
                .padding(12)
                .background(Color.dsSurfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .padding(.bottom, 16)
            }

            if isImporting {
                busyRow("Parsing file…")
            } else {
                Button { showPicker = true } label: {
                    Label(
                        pickedURL == nil ? "Choose .gpx File" : "Choose Different File",
                        systemImage: "folder.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .importing(let done, let total):
            progressCard(processed: done, total: total)

        case .done(let tracks, let cities):
            resultCard(
                icon: "checkmark.circle.fill",
                iconColor: .dsPrimary,
                title: "Import Complete",
                body: "Imported \(tracks) track\(tracks == 1 ? "" : "s") across \(cities) \(cities == 1 ? "city" : "cities")"
            )

        case .failed(let message):
            resultCard(
                icon: "exclamationmark.triangle.fill",
                iconColor: .dsError,
                title: "Import Failed",
                body: message
            )
        }
    }

    // MARK: - Sub-views

    private func cardHeader(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        badge: String?
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconTint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.dsLabelLg())
                    .foregroundColor(.dsOnSurface)
                Text(subtitle)
                    .font(.dsLabelMd())
                    .foregroundColor(.dsOnSurfaceVariant)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.dsLabelSm())
                    .foregroundColor(.dsOutline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.dsSurfaceContainerHigh)
                    .clipShape(Capsule())
            }
        }
    }

    private var dateRangePicker: some View {
        VStack(spacing: 0) {
            dateRow(label: "From", date: $healthStart)
            Divider().background(Color.dsOutlineVariant.opacity(0.2))
            dateRow(label: "To",   date: $healthEnd)
        }
        .background(Color.dsSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }

    private func dateRow(label: String, date: Binding<Date>) -> some View {
        HStack {
            Text(label)
                .font(.dsLabelLg())
                .foregroundColor(.dsOnSurface)
                .frame(width: 36, alignment: .leading)
            DatePicker("", selection: date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .tint(.dsPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var workoutCountBadge: some View {
        if let count = workoutCount {
            HStack(spacing: 8) {
                Image(systemName: count > 0 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundColor(count > 0 ? .dsPrimary : .dsOutline)
                    .font(.system(size: 13))
                Text(count == 0
                     ? "No workouts found in this range"
                     : "\(count) workout\(count == 1 ? "" : "s") available")
                    .font(.dsLabelMd())
                    .foregroundColor(count > 0 ? .dsOnSurface : .dsOnSurfaceVariant)
            }
        }
    }

    private func busyRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(.dsPrimary)
            Text(label)
                .font(.dsLabelLg())
                .foregroundColor(.dsOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func progressCard(processed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProgressView().tint(.dsPrimary)
                    .padding(.trailing, 4)
                Text("Importing…")
                    .font(.dsLabelLg())
                    .foregroundColor(.dsOnSurface)
                Spacer()
                if total > 0 {
                    Text("\(processed) / \(total)")
                        .font(.dsLabelMd())
                        .foregroundColor(.dsOnSurfaceVariant)
                        .monospacedDigit()
                }
            }

            if total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.dsSurfaceContainerHigh)
                            .frame(height: 4)
                        Capsule()
                            .fill(LinearGradient.primaryCTA)
                            .frame(
                                width: max(0, geo.size.width * Double(processed) / Double(total)),
                                height: 4
                            )
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(16)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func resultCard(
        icon: String, iconColor: Color, title: String, body: String
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.dsLabelLg())
                    .foregroundColor(.dsOnSurface)
                Text(body)
                    .font(.dsLabelMd())
                    .foregroundColor(.dsOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.dsSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    // MARK: - Helpers

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    // MARK: - Import Logic

    private func runHealthImport() async {
        guard let userId = auth.currentUserId else { return }

        // 1. Authorization
        do {
            try await health.requestAuthorization()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // 2. Count available workouts (shows badge before starting)
        let count = (try? await health.countWorkouts(from: healthStart, to: healthEnd)) ?? 0
        workoutCount = count
        guard count > 0 else {
            phase = .done(tracks: 0, cities: 0)
            return
        }

        phase = .importing(processed: 0, total: count)

        // 3. Fetch routes (this is the slow step)
        let routes: [ExplorationTrack]
        do {
            routes = try await health.fetchWorkoutRoutes(
                from: healthStart, to: healthEnd, userId: userId
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // 4. Process each track
        var citiesSet = Set<String>()
        for i in 0..<routes.count {
            phase = .importing(processed: i, total: routes.count)
            var track = routes[i]
            let (cityName, country) = await cityService.detectCity(from: track)
            track.cityName = cityName
            try? await trackService.saveTrackLocally(track)
            _ = try? await cityService.saveOrUpdateCity(
                cityName: cityName, country: country, track: track, userId: userId
            )
            citiesSet.insert(cityName)
        }

        await cityService.refresh(userId: userId)
        phase = .done(tracks: routes.count, cities: citiesSet.count)
    }

    private func runGPXImport(url: URL) async {
        guard let userId = auth.currentUserId else { return }
        phase = .importing(processed: 0, total: 1)

        do {
            var track = try gpxParser.parse(url: url, userId: userId)
            let (cityName, country) = await cityService.detectCity(from: track)
            track.cityName = cityName
            try await trackService.saveTrackLocally(track)
            _ = try? await cityService.saveOrUpdateCity(
                cityName: cityName, country: country, track: track, userId: userId
            )
            await cityService.refresh(userId: userId)
            phase = .done(tracks: 1, cities: 1)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Preview

#Preview {
    ImportView()
        .environmentObject(TrackService())
        .environmentObject(CityService())
        .environmentObject(AuthViewModel())
}
