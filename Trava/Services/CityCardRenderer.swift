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
        let padding: CGFloat = max(8, size.width * 0.07)

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

    // MARK: - Mercator projection

    private struct Projection {
        let minLon: Double
        let minMY:  Double   // min Mercator Y
        let scale:  Double
        let offsetX: Double  // additional centering offset in points
        let offsetY: Double
        let size:   CGSize
        let padding: CGFloat

        func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let latRad = coord.latitude  * .pi / 180
            let my     = log(tan(.pi / 4 + latRad / 2)) * 180 / .pi
            let x = (coord.longitude - minLon) * scale + Double(padding) + offsetX
            // Canvas y increases downward; map Mercator y increases northward → flip.
            let y = Double(size.height) - ((my - minMY) * scale + Double(padding) + offsetY)
            return CGPoint(x: x, y: y)
        }
    }

    /// Projects geographic coordinates to canvas points, fitting with uniform scale + centering.
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
            let proj = Projection(minLon: 0, minMY: 0, scale: 1,
                                  offsetX: 0, offsetY: 0, size: size, padding: padding)
            return ([], proj)
        }

        let availW = Double(size.width)  - 2 * Double(padding)
        let availH = Double(size.height) - 2 * Double(padding)
        let spanLon = maxLon - minLon
        let spanMY  = maxMY  - minMY

        let scaleX = spanLon > 0 ? availW / spanLon : 1
        let scaleY = spanMY  > 0 ? availH / spanMY  : 1
        let scale  = min(scaleX, scaleY)

        // Centre within available area
        let usedW  = spanLon * scale
        let usedH  = spanMY  * scale
        let offX   = (availW - usedW) / 2
        let offY   = (availH - usedH) / 2

        let proj = Projection(
            minLon: minLon, minMY: minMY, scale: scale,
            offsetX: offX, offsetY: offY,
            size: size, padding: padding
        )
        return (coords.map { proj.project($0) }, proj)
    }

    // MARK: - Helpers

    private static func makeRenderer(size: CGSize, scale: CGFloat) -> UIGraphicsImageRenderer {
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
