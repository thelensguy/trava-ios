//  Services/CitySnapshotRenderer.swift
//  Trava
//
//  Renders a shareable 1080×1080 UIImage for a City in the app's
//  city-outline card style — dark background, glowing OSM boundary,
//  lava-colour track paths, and a stats panel below the shape.
//
//  Pipeline:
//    1. Fetch OSM boundary polygon via OSMService (with full fallback chain)
//    2. Fall back to a bounding-box rectangle derived from city.coordinates
//       when no OSM boundary is available
//    3. Render entirely in CoreGraphics — no MKMapSnapshotter

import UIKit
import CoreLocation

// MARK: - Errors

enum SnapshotError: LocalizedError {
    case noCoordinates

    var errorDescription: String? {
        "This city has no recorded coordinates yet. Complete a tracking session first."
    }
}

// MARK: - Renderer

@MainActor
struct CitySnapshotRenderer {

    private static let canvasSize:  CGSize  = CGSize(width: 1080, height: 1080)
    private static let statsHeight: CGFloat = 240   // bottom panel reserved for text
    private static let padding:     CGFloat = 80
    private static let leftMargin:  CGFloat = 60

    // MARK: - Public API

    func render(city: City, tracks: [ExplorationTrack]) async throws -> UIImage {
        // Fetch OSM boundary (uses full 4-attempt fallback chain in OSMService).
        let rawBoundary = await OSMService.shared.fetchCityBoundary(
            cityName:           city.cityName,
            country:            city.country,
            administrativeArea: city.administrativeArea.isEmpty ? nil : city.administrativeArea,
            coordinates:        city.coordinates.first?.clCoordinate
        )

        // Resolve: OSM polygon → bounding-box fallback → hard error.
        let boundary: [[Double]]
        if let pts = rawBoundary, pts.count >= 3 {
            boundary = pts
        } else if city.coordinates.count >= 3 {
            boundary = boundingBoxBoundary(from: city.coordinates)
        } else {
            throw SnapshotError.noCoordinates
        }

        return renderCard(boundary: boundary, city: city, tracks: tracks)
    }

    // MARK: - Bounding-box fallback

    /// Builds a closed rectangular [[lon, lat]] boundary from GPS track coordinates.
    private func boundingBoxBoundary(from coords: [Coordinate]) -> [[Double]] {
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }
        let pad = max((maxLat - minLat) * 0.15, (maxLon - minLon) * 0.15, 0.005)
        return [
            [minLon - pad, maxLat + pad],  // top-left
            [maxLon + pad, maxLat + pad],  // top-right
            [maxLon + pad, minLat - pad],  // bottom-right
            [minLon - pad, minLat - pad],  // bottom-left
            [minLon - pad, maxLat + pad],  // close
        ]
    }

    // MARK: - CoreGraphics render

    private func renderCard(
        boundary: [[Double]],
        city:     City,
        tracks:   [ExplorationTrack]
    ) -> UIImage {
        let size      = Self.canvasSize
        let statsH    = Self.statsHeight
        let padding   = Self.padding
        let lm        = Self.leftMargin

        // Shape occupies only the top portion; projection is computed within this zone
        // so the boundary always fits without clipping into the stats panel.
        let shapeH    = size.height - statsH               // 840 pt
        let shapeSize = CGSize(width: size.width, height: shapeH)

        let format        = UIGraphicsImageRendererFormat()
        format.scale      = 1.0    // 1 pt = 1 px → exact 1080×1080 px output
        format.opaque     = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext

            // ── 1. Background ─────────────────────────────────────────────
            c.setFillColor(UIColor(hex6: "0D0D0D").cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            // ── 2. Project boundary [lon, lat] pairs → CGPoints ───────────
            //    Projection is fitted to shapeSize so the boundary always
            //    stays within the top 840 pt with 80 pt padding on all sides.
            let clCoords = boundary.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            let (boundaryPts, proj) = Self.project(clCoords, size: shapeSize, padding: padding)
            guard boundaryPts.count >= 3 else { return }

            // ── 3. Boundary closed path ───────────────────────────────────
            let boundaryPath = CGMutablePath()
            boundaryPath.move(to: boundaryPts[0])
            boundaryPts.dropFirst().forEach { boundaryPath.addLine(to: $0) }
            boundaryPath.closeSubpath()

            // ── 4. City fill ──────────────────────────────────────────────
            c.saveGState()
            c.addPath(boundaryPath)
            c.setFillColor(UIColor(hex6: "1A1A2E").cgColor)
            c.fillPath()
            c.restoreGState()

            // ── 5. Boundary glow (wide dim + narrow bright) ───────────────
            let glowColor = UIColor(hex6: "adc6ff")

            c.saveGState()
            c.addPath(boundaryPath)
            c.setStrokeColor(glowColor.withAlphaComponent(0.20).cgColor)
            c.setLineWidth(4)
            c.strokePath()
            c.restoreGState()

            c.saveGState()
            c.addPath(boundaryPath)
            c.setStrokeColor(glowColor.withAlphaComponent(0.70).cgColor)
            c.setLineWidth(2)
            c.strokePath()
            c.restoreGState()

            // ── 6. Track paths (clipped to boundary, 3-pass lava glow) ───
            if !tracks.isEmpty {
                c.saveGState()
                c.addPath(boundaryPath)
                c.clip()

                for track in tracks {
                    guard track.coordinates.count >= 2 else { continue }

                    // Subsample long tracks for render performance.
                    let raw    = track.coordinates
                    let stride = max(1, raw.count / 400)
                    let sample = stride > 1
                        ? raw.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
                        : raw
                    guard sample.count >= 2 else { continue }

                    let trackPts = sample.map {
                        proj.project(CLLocationCoordinate2D(latitude: $0.latitude,
                                                            longitude: $0.longitude))
                    }
                    let trackPath = CGMutablePath()
                    trackPath.move(to: trackPts[0])
                    trackPts.dropFirst().forEach { trackPath.addLine(to: $0) }

                    let passes: [(width: CGFloat, hex: String, alpha: CGFloat)] = [
                        (16, "FF4500", 0.35),   // outer glow
                        (10, "FF6B35", 0.65),   // mid
                        ( 4, "FFE4A0", 1.00),   // bright core
                    ]
                    for pass in passes {
                        c.saveGState()
                        c.addPath(trackPath)
                        c.setStrokeColor(UIColor(hex6: pass.hex).withAlphaComponent(pass.alpha).cgColor)
                        c.setLineWidth(pass.width)
                        c.setLineCap(.round)
                        c.setLineJoin(.round)
                        c.strokePath()
                        c.restoreGState()
                    }
                }

                c.restoreGState()
            }

            // ── 7. Stats panel — solid bottom 240 pt ──────────────────────
            let statsY = shapeH   // 840
            c.setFillColor(UIColor(hex6: "0D0D0D").cgColor)
            c.fill(CGRect(x: 0, y: statsY, width: size.width, height: statsH))

            // Country label — 28 pt, #adc6ff, tracked caps, y=860
            let countryFont = UIFont(name: "Inter-Medium", size: 28)
                ?? .systemFont(ofSize: 28, weight: .medium)
            let countryAttrs: [NSAttributedString.Key: Any] = [
                .font:            countryFont,
                .foregroundColor: glowColor,
                .kern:            3.0,
            ]
            (city.country.uppercased() as NSString)
                .draw(at: CGPoint(x: lm, y: 860), withAttributes: countryAttrs)

            // City name — 72 pt bold, white, single line with tail truncation, y=900
            let cityFont = UIFont(name: "PlusJakartaSans-Bold", size: 72)
                ?? .boldSystemFont(ofSize: 72)
            let cityPS   = NSMutableParagraphStyle()
            cityPS.lineBreakMode = .byTruncatingTail
            let cityAttrs: [NSAttributedString.Key: Any] = [
                .font:            cityFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle:  cityPS,
            ]
            let cityRect = CGRect(x: lm, y: 900, width: size.width - lm * 2, height: 90)
            (city.cityName as NSString).draw(in: cityRect, withAttributes: cityAttrs)

            // Stats row — 24 pt, #adc6ff at 70 %, miles, y=980
            let statsFont = UIFont(name: "Inter-Regular", size: 24)
                ?? .systemFont(ofSize: 24)
            let distMi    = city.totalDistanceKm * 0.621371
            let distStr   = distMi < 10
                ? String(format: "%.1f mi", distMi)
                : String(format: "%.0f mi", distMi)
            let coverage  = Int((city.coveragePercent * 100).rounded())
            let sessions  = city.totalSessions
            let statsText = "\(distStr) · \(sessions) session\(sessions == 1 ? "" : "s") · \(coverage)% explored"
            let statsAttrs: [NSAttributedString.Key: Any] = [
                .font:            statsFont,
                .foregroundColor: glowColor.withAlphaComponent(0.70),
            ]
            (statsText as NSString).draw(at: CGPoint(x: lm, y: 980), withAttributes: statsAttrs)

            // TRAVA wordmark — 28 pt, white at 40 %, right-aligned at x=1020, y=1050
            let markFont = UIFont(name: "PlusJakartaSans-Bold", size: 28)
                ?? .boldSystemFont(ofSize: 28)
            let markText = "TRAVA"
            let markAttrs: [NSAttributedString.Key: Any] = [
                .font:            markFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.40),
                .kern:            4.0,
            ]
            let markSize = (markText as NSString).size(withAttributes: markAttrs)
            (markText as NSString).draw(
                at: CGPoint(x: 1020 - markSize.width, y: 1050),
                withAttributes: markAttrs
            )
        }
    }

    // MARK: - Two-pass Mercator projection

    // Identical algorithm to CityCardRenderer.Projection — kept local so
    // CitySnapshotRenderer has no cross-file dependency on that type.
    //
    // Pass 1 maps geographic coords to a preliminary pixel space using the
    // geographic span.  Pass 2 measures the actual pixel bounding box and
    // re-centres/re-scales to fit exactly within the padded canvas.

    private struct Projection {
        let minLon:     Double
        let minMY:      Double
        let p1Scale:    Double
        let padding:    CGFloat
        let size:       CGSize
        let pixMinX:    Double
        let pixMinY:    Double
        let p2Scale:    Double
        let centerOffX: Double
        let centerOffY: Double

        func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let latRad = coord.latitude * .pi / 180
            let my     = log(tan(.pi / 4 + latRad / 2)) * 180 / .pi
            let rawX   = (coord.longitude - minLon) * p1Scale + Double(padding)
            // Mercator Y increases northward; CGContext Y increases downward → flip.
            let rawY   = Double(size.height) - ((my - minMY) * p1Scale + Double(padding))
            return CGPoint(
                x: (rawX - pixMinX) * p2Scale + centerOffX,
                y: (rawY - pixMinY) * p2Scale + centerOffY
            )
        }
    }

    private static func project(
        _ coords: [CLLocationCoordinate2D],
        size:     CGSize,
        padding:  CGFloat
    ) -> ([CGPoint], Projection) {
        let lons = coords.map { $0.longitude }
        let mys  = coords.map { c -> Double in
            let r = c.latitude * .pi / 180
            return log(tan(.pi / 4 + r / 2)) * 180 / .pi
        }

        guard
            let minLon = lons.min(), let maxLon = lons.max(),
            let minMY  = mys.min(),  let maxMY  = mys.max()
        else {
            let fallback = Projection(
                minLon: 0, minMY: 0, p1Scale: 1, padding: padding, size: size,
                pixMinX: 0, pixMinY: 0, p2Scale: 1,
                centerOffX: Double(padding), centerOffY: Double(padding)
            )
            return ([], fallback)
        }

        // Pass 1 — preliminary scale from geographic span
        let availW  = Double(size.width)  - 2 * Double(padding)
        let availH  = Double(size.height) - 2 * Double(padding)
        let spanLon = max(maxLon - minLon, 1e-9)
        let spanMY  = max(maxMY  - minMY,  1e-9)
        let p1Scale = min(availW / spanLon, availH / spanMY)

        let rawPts: [CGPoint] = zip(lons, mys).map { lon, my in
            CGPoint(
                x: (lon - minLon) * p1Scale + Double(padding),
                y: Double(size.height) - ((my - minMY) * p1Scale + Double(padding))
            )
        }

        // Pass 2 — measure pixel bounding box, re-fit to padded canvas
        let pixMinX = rawPts.map { $0.x }.min()!
        let pixMaxX = rawPts.map { $0.x }.max()!
        let pixMinY = rawPts.map { $0.y }.min()!
        let pixMaxY = rawPts.map { $0.y }.max()!
        let pixW    = max(pixMaxX - pixMinX, 1)
        let pixH    = max(pixMaxY - pixMinY, 1)

        let targetW = Double(size.width)  - 2 * Double(padding)
        let targetH = Double(size.height) - 2 * Double(padding)
        let p2Scale = min(targetW / pixW, targetH / pixH)

        let scaledW    = pixW * p2Scale
        let scaledH    = pixH * p2Scale
        let centerOffX = (Double(size.width)  - scaledW) / 2
        let centerOffY = (Double(size.height) - scaledH) / 2

        let proj = Projection(
            minLon: minLon, minMY: minMY, p1Scale: p1Scale, padding: padding, size: size,
            pixMinX: pixMinX, pixMinY: pixMinY, p2Scale: p2Scale,
            centerOffX: centerOffX, centerOffY: centerOffY
        )
        return (rawPts.map { raw in
            CGPoint(
                x: (raw.x - pixMinX) * p2Scale + centerOffX,
                y: (raw.y - pixMinY) * p2Scale + centerOffY
            )
        }, proj)
    }
}

// MARK: - UIColor hex convenience (private to this file)

private extension UIColor {
    /// Initialise from a 6-character hex string (no leading `#`).
    convenience init(hex6: String) {
        let v = UInt64(hex6, radix: 16) ?? 0
        self.init(
            red:   CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >>  8) & 0xFF) / 255,
            blue:  CGFloat( v        & 0xFF) / 255,
            alpha: 1
        )
    }
}
