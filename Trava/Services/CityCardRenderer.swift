//  Services/CityCardRenderer.swift
//  Trava
//
//  Pure CoreGraphics renderer for city boundary silhouette cards.
//
//  Visual spec:
//    Background : #0D0D0D
//    City fill  : #1A1A2E
//    Boundary   : #adc6ff glow (3-pass: wide dim → medium → thin bright)
//    Track paths: #FF6B35 spine clipped to city boundary
//    Empty state: city initial letter centred

// @preconcurrency suppresses "this is an error in Swift 6" warnings for UIKit APIs
// that are annotated @MainActor in the SDK.  UIGraphicsImageRenderer is documented
// as safe to call from any thread (it doesn't touch the UIView hierarchy).
@preconcurrency import UIKit
import CoreLocation

enum CityCardRenderer {

    // MARK: - Public API

    /// Renders the city boundary with the user's track paths overlaid.
    /// nonisolated: UIGraphicsImageRenderer is thread-safe; no UIView access.
    nonisolated static func render(
        boundary:    [[Double]],        // [lon, lat] pairs from OSM
        trackCoords: [Coordinate],      // user's recorded coords
        size:        CGSize,
        scale:       CGFloat = 2
    ) -> UIImage {
        makeRenderer(size: size, scale: scale).image { ctx in
            drawCard(in: ctx.cgContext, size: size,
                     boundary: boundary, trackCoords: trackCoords)
        }
    }

    /// Renders a placeholder card (city initials) when no boundary is available.
    nonisolated static func renderPlaceholder(cityName: String, size: CGSize, scale: CGFloat = 2) -> UIImage {
        makeRenderer(size: size, scale: scale).image { ctx in
            let c = ctx.cgContext
            // Dark background
            c.setFillColor(UIColor(hex6: "0D0D0D").cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            // Subtle city initial
            let fontSize = size.width * 0.38
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor(hex6: "adc6ff").withAlphaComponent(0.35),
            ]
            let letter   = NSAttributedString(string: String(cityName.prefix(1)).uppercased(), attributes: attrs)
            let sz       = letter.size()
            letter.draw(at: CGPoint(x: (size.width - sz.width) / 2,
                                    y: (size.height - sz.height) / 2))
        }
    }

    // MARK: - Core draw

    private static func drawCard(
        in ctx:       CGContext,
        size:         CGSize,
        boundary:     [[Double]],
        trackCoords:  [Coordinate]
    ) {
        let padding: CGFloat = 36

        // 1. Background
        ctx.setFillColor(UIColor(hex6: "0D0D0D").cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        guard boundary.count >= 3 else { return }

        // 2. Project boundary coords to canvas
        let clCoords = boundary.map {
            CLLocationCoordinate2D(latitude: $0.count > 1 ? $0[1] : 0,
                                   longitude: $0.count > 0 ? $0[0] : 0)
        }
        let (pts, proj) = project(clCoords, size: size, padding: padding)
        guard pts.count >= 3 else { return }

        // 3. Build boundary path
        let path = CGMutablePath()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()

        // 4. Fill city body
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(UIColor(hex6: "1A1A2E").cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 5. Boundary glow — three passes
        let glowColor = UIColor(hex6: "adc6ff")
        let passes: [(width: CGFloat, alpha: CGFloat)] = [
            (6.0, 0.12),
            (2.5, 0.40),
            (1.2, 0.85),
        ]
        for pass in passes {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(glowColor.withAlphaComponent(pass.alpha).cgColor)
            ctx.setLineWidth(pass.width)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 6. Track paths (clipped to city boundary)
        guard !trackCoords.isEmpty else { return }

        // Subsample to keep path complexity manageable
        let raw    = trackCoords
        let stride = max(1, raw.count / 400)
        let sample = stride > 1
            ? raw.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
            : raw
        guard sample.count >= 2 else { return }

        let trackPts = sample.map {
            proj.project(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }

        let trackPath = CGMutablePath()
        trackPath.move(to: trackPts[0])
        for pt in trackPts.dropFirst() { trackPath.addLine(to: pt) }

        ctx.saveGState()
        ctx.addPath(path)           // clip to city boundary
        ctx.clip()
        ctx.addPath(trackPath)
        ctx.setStrokeColor(UIColor(hex6: "FF6B35").withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(max(1.0, size.width / 80))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Mercator projection (two-pass)

    // Pass 1 maps geographic coords to preliminary pixel space.
    // Pass 2 measures the actual pixel bounding box and re-fits it to the padded
    // canvas — this guarantees any city shape fits completely regardless of aspect
    // ratio or Mercator distortion, and is reusable for track coords via project().
    private struct Projection {
        // Pass 1
        let minLon:  Double
        let minMY:   Double
        let p1Scale: Double
        let padding: CGFloat
        let size:    CGSize
        // Pass 2 adjustment
        let pixMinX:    Double
        let pixMinY:    Double
        let p2Scale:    Double
        let centerOffX: Double
        let centerOffY: Double

        func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let latRad = coord.latitude * .pi / 180
            let my     = log(tan(.pi / 4 + latRad / 2)) * 180 / .pi
            let rawX   = (coord.longitude - minLon) * p1Scale + Double(padding)
            // Mercator Y increases northward; canvas Y increases downward → flip.
            let rawY   = Double(size.height) - ((my - minMY) * p1Scale + Double(padding))
            return CGPoint(
                x: (rawX - pixMinX) * p2Scale + centerOffX,
                y: (rawY - pixMinY) * p2Scale + centerOffY
            )
        }
    }

    private static func project(
        _ coords: [CLLocationCoordinate2D],
        size: CGSize,
        padding: CGFloat
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
            return ([], Projection(minLon: 0, minMY: 0, p1Scale: 1, padding: padding, size: size,
                                   pixMinX: 0, pixMinY: 0, p2Scale: 1,
                                   centerOffX: Double(padding), centerOffY: Double(padding)))
        }

        // Pass 1 — preliminary scale from geographic span
        let availW  = Double(size.width)  - 2 * Double(padding)
        let availH  = Double(size.height) - 2 * Double(padding)
        let spanLon = max(maxLon - minLon, 1e-9)
        let spanMY  = max(maxMY  - minMY,  1e-9)
        let p1Scale = min(availW / spanLon, availH / spanMY)

        // Pass 1 raw pixel points
        let rawPts: [CGPoint] = zip(lons, mys).map { lon, my in
            CGPoint(x: (lon - minLon) * p1Scale + Double(padding),
                    y: Double(size.height) - ((my - minMY) * p1Scale + Double(padding)))
        }

        // Pass 2 — measure actual pixel bounding box and fit to canvas
        let pixMinX = rawPts.map { $0.x }.min()!
        let pixMaxX = rawPts.map { $0.x }.max()!
        let pixMinY = rawPts.map { $0.y }.min()!
        let pixMaxY = rawPts.map { $0.y }.max()!
        let pixW    = max(pixMaxX - pixMinX, 1)
        let pixH    = max(pixMaxY - pixMinY, 1)

        let targetW = Double(size.width)  - 2 * Double(padding)
        let targetH = Double(size.height) - 2 * Double(padding)
        let p2Scale = min(targetW / pixW, targetH / pixH)

        let scaledW    = pixW    * p2Scale
        let scaledH    = pixH    * p2Scale
        let centerOffX = (Double(size.width)  - scaledW) / 2
        let centerOffY = (Double(size.height) - scaledH) / 2

        let proj = Projection(
            minLon: minLon, minMY: minMY, p1Scale: p1Scale, padding: padding, size: size,
            pixMinX: pixMinX, pixMinY: pixMinY, p2Scale: p2Scale,
            centerOffX: centerOffX, centerOffY: centerOffY
        )
        return (rawPts.map { raw in
            CGPoint(x: (raw.x - pixMinX) * p2Scale + centerOffX,
                    y: (raw.y - pixMinY) * p2Scale + centerOffY)
        }, proj)
    }

    // MARK: - Helpers

    nonisolated private static func makeRenderer(size: CGSize, scale: CGFloat) -> UIGraphicsImageRenderer {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale  = scale
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt)
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
