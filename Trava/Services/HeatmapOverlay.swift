//  Services/HeatmapOverlay.swift
//  Trava
//
//  Strava-style glowing path heatmap.
//  Renders GPS track segments as three-layer glowing lines.
//
//  Layer order (drawn lowest → highest so cores always sit on top):
//    Pass 1 — base halo : wide, low opacity  → builds the outer glow
//    Pass 2 — mid glow  : medium, mid opacity → warm fill
//    Pass 3 — core line : thin,  high opacity → bright center spine
//
//  Density is measured by counting how many segments share the same
//  5000-bucket (≈ 22 m grid). Denser buckets glow brighter and shift
//  colour from orange-red → gold → white.
//
//  Every loadTile call returns valid PNG Data (even empty tiles return a
//  1×1 transparent PNG) to prevent MapKit "Failed to decode key" errors.

#if canImport(UIKit)
import UIKit
import MapKit
import CoreLocation

final class HeatmapOverlay: MKTileOverlay {

    // MARK: - Private types

    private struct Segment {
        let a: CLLocationCoordinate2D
        let b: CLLocationCoordinate2D

        var midLat: Double { (a.latitude  + b.latitude)  * 0.5 }
        var midLon: Double { (a.longitude + b.longitude) * 0.5 }
        var minLat: Double { min(a.latitude,  b.latitude)  }
        var maxLat: Double { max(a.latitude,  b.latitude)  }
        var minLon: Double { min(a.longitude, b.longitude) }
        var maxLon: Double { max(a.longitude, b.longitude) }
    }

    private struct LineWidths {
        let base: CGFloat
        let mid:  CGFloat
        let core: CGFloat
    }

    private struct GlowPalette {
        let base: UIColor
        let mid:  UIColor
        let core: UIColor
    }

    // Precomputed data for one renderable segment.
    private struct RenderUnit {
        let p1:      CGPoint
        let p2:      CGPoint
        let mult:    CGFloat      // density opacity multiplier
        let palette: GlowPalette
    }

    // MARK: - Stored data

    private let segments: [Segment]
    /// User-selected intensity multiplier (0.5 – 2.0).
    /// Must be set before the overlay is added to the map; changing it after
    /// tiles are cached has no effect — replace the overlay entirely instead.
    var intensity: Double = 1.0

    // Valid 1×1 transparent PNG; allocated once, reused for every empty tile.
    private static let transparentPixel: Data = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
    }()

    // MARK: - Init

    /// - Parameters:
    ///   - tracks: Each element is one GPS track as an ordered coordinate array.
    ///   - intensity: User multiplier (0.5 – 2.0); stored from @AppStorage.
    init(tracks: [[CLLocationCoordinate2D]], intensity: Double = 1.0) {
        self.segments = tracks.flatMap { track -> [Segment] in
            guard track.count >= 2 else { return [] }
            return zip(track, track.dropFirst()).map { Segment(a: $0, b: $1) }
        }
        self.intensity = max(0.5, min(2.0, intensity))
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize             = CGSize(width: 512, height: 512)
        minimumZ             = 10
        maximumZ             = 18
    }

    // MARK: - MKTileOverlay

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, Error?) -> Void
    ) {
        let z = path.z, x = path.x, y = path.y
        let (minLat, maxLat, minLon, maxLon) = tileBounds(x: x, y: y, z: z)

        // Degree buffer so glowing lines that start just outside still bleed in.
        let widths      = lineWidths(zoom: z)
        let n           = pow(2.0, Double(z))
        let pxPerDegLon = Double(tileSize.width) * n / 360.0
        let bufLon      = Double(widths.base) / pxPerDegLon
        let bufLat      = bufLon   // latitude degrees ≈ longitude degrees at city scale

        let candidates = segments.filter { seg in
            seg.maxLat >= minLat - bufLat && seg.minLat <= maxLat + bufLat &&
            seg.maxLon >= minLon - bufLon && seg.minLon <= maxLon + bufLon
        }

        guard !candidates.isEmpty else {
            result(Self.transparentPixel, nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { result(Self.transparentPixel, nil); return }
            let data = self.renderTile(
                candidates: candidates,
                minLat: minLat, maxLat: maxLat,
                minLon: minLon, maxLon: maxLon,
                zoom: z
            )
            result(data, nil)
        }
    }

    // MARK: - Tile rendering

    private func renderTile(
        candidates: [Segment],
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        zoom: Int
    ) -> Data {
        let fSide      = tileSize.width
        let baseWidths = lineWidths(zoom: zoom)
        // Intensity scales line widths: thin+faint at 0.5×, thick+bright at 2.0×
        let widthScale = CGFloat(max(0.6, min(intensity, 1.8)))
        let widths     = LineWidths(
            base: baseWidths.base * widthScale,
            mid:  baseWidths.mid  * widthScale,
            core: baseWidths.core * widthScale
        )
        let iFactor = CGFloat(intensity)

        // Density map: how many segments share each ~22 m bucket.
        var densityMap: [Int64: Int] = [:]
        densityMap.reserveCapacity(candidates.count)
        for seg in candidates {
            densityMap[bucketKey(lat: seg.midLat, lon: seg.midLon), default: 0] += 1
        }

        // Pre-project all segments and cache per-segment render parameters
        // so the three passes don't repeat the same calculations.
        let units: [RenderUnit] = candidates.map { seg in
            let density = densityMap[bucketKey(lat: seg.midLat, lon: seg.midLon), default: 1]
            return RenderUnit(
                p1:      project(seg.a, side: fSide,
                                 minLat: minLat, maxLat: maxLat,
                                 minLon: minLon, maxLon: maxLon),
                p2:      project(seg.b, side: fSide,
                                 minLat: minLat, maxLat: maxLat,
                                 minLon: minLon, maxLon: maxLon),
                mult:    densityMultiplier(density),
                palette: glowPalette(density: density)
            )
        }

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: Int(fSide), height: Int(fSide))
        )
        return renderer.pngData { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)

            // ── Pass 1: outer halo (wide, low opacity) ────────────────────
            cgCtx.setLineWidth(widths.base)
            for u in units {
                let alpha = min(0.15 * u.mult * iFactor, 1.0)
                cgCtx.setStrokeColor(u.palette.base.withAlphaComponent(alpha).cgColor)
                cgCtx.move(to: u.p1)
                cgCtx.addLine(to: u.p2)
                cgCtx.strokePath()
            }

            // ── Pass 2: mid glow ──────────────────────────────────────────
            cgCtx.setLineWidth(widths.mid)
            for u in units {
                let alpha = min(0.40 * u.mult * iFactor, 1.0)
                cgCtx.setStrokeColor(u.palette.mid.withAlphaComponent(alpha).cgColor)
                cgCtx.move(to: u.p1)
                cgCtx.addLine(to: u.p2)
                cgCtx.strokePath()
            }

            // ── Pass 3: core spine (thin, high opacity) ───────────────────
            cgCtx.setLineWidth(widths.core)
            for u in units {
                let alpha = min(0.90 * u.mult * iFactor, 1.0)
                cgCtx.setStrokeColor(u.palette.core.withAlphaComponent(alpha).cgColor)
                cgCtx.move(to: u.p1)
                cgCtx.addLine(to: u.p2)
                cgCtx.strokePath()
            }
        }
    }

    // MARK: - Projection

    private func project(
        _ coord: CLLocationCoordinate2D,
        side: CGFloat,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> CGPoint {
        CGPoint(
            x: CGFloat((coord.longitude - minLon) / (maxLon - minLon)) * side,
            y: CGFloat((maxLat - coord.latitude)  / (maxLat - minLat)) * side
        )
    }

    // MARK: - Density helpers

    /// Stable 64-bit key for a ~22 m lat/lon bucket (5000 buckets per degree).
    private func bucketKey(lat: Double, lon: Double) -> Int64 {
        // lon shifted to [0, 360] to keep all values positive.
        Int64(lat * 5000) &* 2_000_000 &+ Int64((lon + 180.0) * 5000)
    }

    private func densityMultiplier(_ count: Int) -> CGFloat {
        switch count {
        case 1:     return 1.0
        case 2...3: return 1.4
        case 4...6: return 1.8
        default:    return 2.2
        }
    }

    // MARK: - Color palettes

    private func glowPalette(density: Int) -> GlowPalette {
        switch density {
        case ..<3:
            // Low density — orange-red
            return GlowPalette(
                base: UIColor(red: 1.000, green: 0.271, blue: 0.000, alpha: 1), // #FF4500
                mid:  UIColor(red: 1.000, green: 0.420, blue: 0.208, alpha: 1), // #FF6B35
                core: UIColor(red: 1.000, green: 0.961, blue: 0.627, alpha: 1)  // #FFF5C0
            )
        case 3..<7:
            // Mid density — shifting toward gold
            return GlowPalette(
                base: UIColor(red: 1.000, green: 0.420, blue: 0.208, alpha: 1), // #FF6B35
                mid:  UIColor(red: 1.000, green: 0.843, blue: 0.000, alpha: 1), // #FFD700
                core: UIColor(red: 1.000, green: 0.961, blue: 0.627, alpha: 1)  // #FFF5C0
            )
        default:
            // High density — gold / pure white core
            return GlowPalette(
                base: UIColor(red: 1.000, green: 0.843, blue: 0.000, alpha: 1), // #FFD700
                mid:  UIColor(red: 1.000, green: 0.894, blue: 0.290, alpha: 1), // #FFE44A
                core: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)  // #FFFFFF
            )
        }
    }

    // MARK: - Zoom-adaptive line widths

    private func lineWidths(zoom: Int) -> LineWidths {
        switch zoom {
        case ..<13:    return LineWidths(base: 10, mid: 6,  core: 2.0)
        case 13...14:  return LineWidths(base: 8,  mid: 5,  core: 1.5)
        case 15...16:  return LineWidths(base: 6,  mid: 4,  core: 1.5)
        default:       return LineWidths(base: 4,  mid: 3,  core: 1.0)
        }
    }

    // MARK: - Tile math (Slippy Map / Web Mercator)

    private func tileBounds(x: Int, y: Int, z: Int) -> (Double, Double, Double, Double) {
        let n      = pow(2.0, Double(z))
        let minLon = Double(x)     / n * 360.0 - 180.0
        let maxLon = Double(x + 1) / n * 360.0 - 180.0
        let maxLat = mercatorToLat(y: y,     n: n)
        let minLat = mercatorToLat(y: y + 1, n: n)
        return (minLat, maxLat, minLon, maxLon)
    }

    private func mercatorToLat(y: Int, n: Double) -> Double {
        atan(sinh(.pi * (1.0 - 2.0 * Double(y) / n))) * 180.0 / .pi
    }
}
#endif
