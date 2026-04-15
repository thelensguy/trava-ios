//  Services/CitySnapshotRenderer.swift
//  Trava
//
//  Renders a shareable 1080×1080 UIImage for a City.
//  Pipeline:
//    1. MKMapSnapshotter captures the city's bounding-box region (dark map)
//    2. UIGraphicsImageRenderer composites:
//       - Map as background
//       - Gradient dark overlay for text legibility
//       - City name (PlusJakartaSans Bold) — top left
//       - Country + stats row below
//       - "TRAVA" wordmark — bottom right

import MapKit
import UIKit
import CoreLocation

// MARK: - Errors

enum SnapshotError: LocalizedError {
    case noCoordinates
    case mapCaptureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noCoordinates:
            return "This city has no recorded coordinates yet. Complete a tracking session first."
        case .mapCaptureFailed(let underlying):
            return "Map capture failed: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Renderer

@MainActor
struct CitySnapshotRenderer {

    private static let canvasSize = CGSize(width: 1080, height: 1080)
    private static let margin: CGFloat = 64

    // MARK: - Public API

    /// Renders a shareable snapshot for `city`.
    /// `tracks` is used for future heatmap overlay; currently only `city.coordinates`
    /// drives the map region.
    func render(city: City, tracks: [ExplorationTrack]) async throws -> UIImage {
        guard !city.coordinates.isEmpty else {
            throw SnapshotError.noCoordinates
        }
        let mapImage = try await captureMap(for: city)
        return composite(map: mapImage, city: city)
    }

    // MARK: - Map capture

    private func captureMap(for city: City) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.region     = boundingRegion(for: city.coordinates)
        options.size       = Self.canvasSize
        options.scale      = 1.0   // 1 pt = 1 px → exact 1080×1080 px output
        options.mapType    = .mutedStandard
        options.showsBuildings = true
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return snapshot.image
        } catch {
            throw SnapshotError.mapCaptureFailed(error)
        }
    }

    /// Computes a padded bounding region that fits all city coordinates.
    private func boundingRegion(for coordinates: [Coordinate]) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.02, (maxLat - minLat) * 1.45),
            longitudeDelta: max(0.02, (maxLon - minLon) * 1.45)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Composite

    private func composite(map: UIImage, city: City) -> UIImage {
        let size = Self.canvasSize
        let margin = Self.margin

        // Fixed pixel output — scale 1.0 so layout units == pixels.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // ── 1. Map background ─────────────────────────────────────────
            map.draw(in: CGRect(origin: .zero, size: size))

            // ── 2. Gradient overlay ───────────────────────────────────────
            // Heavier at top (text) and bottom (wordmark), lighter in middle.
            let gradColors = [
                UIColor.black.withAlphaComponent(0.60).cgColor,   // top
                UIColor.black.withAlphaComponent(0.12).cgColor,   // mid
                UIColor.black.withAlphaComponent(0.52).cgColor,   // bottom
            ] as CFArray
            let gradLocations: [CGFloat] = [0.0, 0.5, 1.0]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: gradColors,
                locations: gradLocations
            ) {
                // In UIKit coords: y=0 is TOP, y=size.height is BOTTOM.
                // drawLinearGradient: start → end maps location 0.0 → 1.0.
                // We want location 0.0 at top → start = (0,0).
                cgCtx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end:   CGPoint(x: 0, y: size.height),
                    options: []
                )
            }

            // ── 3. Typography setup ───────────────────────────────────────
            let titleFont   = UIFont(name: "PlusJakartaSans-Bold",   size: 88) ?? .boldSystemFont(ofSize: 88)
            let countryFont = UIFont(name: "Inter-Medium",           size: 30) ?? .systemFont(ofSize: 30, weight: .medium)
            let statsFont   = UIFont(name: "Inter-Regular",          size: 26) ?? .systemFont(ofSize: 26)
            let markFont    = UIFont(name: "PlusJakartaSans-Bold",   size: 22) ?? .boldSystemFont(ofSize: 22)

            let maxWidth = size.width - margin * 2

            // Truncate long city names to one line
            let titlePS = NSMutableParagraphStyle()
            titlePS.lineBreakMode = .byTruncatingTail

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font:           titleFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: titlePS,
            ]

            // ── 4. City name (top-left) ───────────────────────────────────
            let topY: CGFloat = 72
            let titleHeight  = titleFont.lineHeight
            let titleRect    = CGRect(x: margin, y: topY, width: maxWidth, height: titleHeight + 4)
            (city.cityName.uppercased() as NSString).draw(in: titleRect, withAttributes: titleAttrs)

            // ── 5. Country ────────────────────────────────────────────────
            let countryAttrs: [NSAttributedString.Key: Any] = [
                .font:           countryFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.65),
                .kern:           2.5,
            ]
            let countryY    = topY + titleHeight + 10
            let countryHeight = countryFont.lineHeight
            (city.country.uppercased() as NSString).draw(
                at: CGPoint(x: margin, y: countryY),
                withAttributes: countryAttrs
            )

            // ── 6. Stats row ──────────────────────────────────────────────
            let coverage  = Int((city.coveragePercent * 100).rounded())
            let sessions  = city.totalSessions
            let statsText = "\(String(format: "%.1f", city.totalDistanceKm)) km  ·  \(sessions) session\(sessions == 1 ? "" : "s")  ·  \(coverage)% explored"
            let statsAttrs: [NSAttributedString.Key: Any] = [
                .font:           statsFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.80),
            ]
            let statsY = countryY + countryHeight + 20
            (statsText as NSString).draw(at: CGPoint(x: margin, y: statsY), withAttributes: statsAttrs)

            // ── 7. TRAVA wordmark (bottom-right) ──────────────────────────
            let wordmark = "TRAVA"
            let markAttrs: [NSAttributedString.Key: Any] = [
                .font:           markFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.40),
                .kern:           5.0,
            ]
            let markSize  = (wordmark as NSString).size(withAttributes: markAttrs)
            let markPoint = CGPoint(
                x: size.width  - margin - markSize.width,
                y: size.height - margin - markSize.height
            )
            (wordmark as NSString).draw(at: markPoint, withAttributes: markAttrs)
        }
    }
}
