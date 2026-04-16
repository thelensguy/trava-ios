//  DesignSystem.swift
//  Trava
//
//  Design tokens from "The Precision Architect" design system.
//
//  FONTS: To enable custom typography, add these font files to your Xcode project
//  and declare them in Info.plist under "Fonts provided by application":
//    PlusJakartaSans-Bold.ttf, PlusJakartaSans-SemiBold.ttf, PlusJakartaSans-Medium.ttf
//    Inter-Regular.ttf, Inter-Medium.ttf
//  The app falls back to the system font when files are absent.

import SwiftUI

// MARK: - Color Tokens

extension Color {
    // Surface hierarchy
    static let dsSurface                 = Color(hex: "#131313")
    static let dsSurfaceDim              = Color(hex: "#131313")
    static let dsSurfaceBright           = Color(hex: "#393939")
    static let dsSurfaceContainerLowest  = Color(hex: "#0e0e0e")
    static let dsSurfaceContainerLow     = Color(hex: "#1c1b1b")
    static let dsSurfaceContainer        = Color(hex: "#201f1f")
    static let dsSurfaceContainerHigh    = Color(hex: "#2a2a2a")
    static let dsSurfaceContainerHighest = Color(hex: "#353534")
    static let dsBackground              = Color(hex: "#131313")

    // Content
    static let dsOnSurface               = Color(hex: "#e5e2e1")
    static let dsOnSurfaceVariant        = Color(hex: "#c1c6d7")

    // Primary (blue)
    static let dsPrimary                 = Color(hex: "#adc6ff")
    static let dsPrimaryContainer        = Color(hex: "#4b8eff")
    static let dsOnPrimary               = Color(hex: "#002e69")

    // Secondary / heatmap (coral)
    static let dsSecondary               = Color(hex: "#ffb3ae")
    static let dsSecondaryContainer      = Color(hex: "#ad031a")
    static let dsOnSecondary             = Color(hex: "#68000b")

    // Tertiary (orange)
    static let dsTertiary                = Color(hex: "#ffb595")
    static let dsTertiaryContainer       = Color(hex: "#ef6719")

    // Outline
    static let dsOutline                 = Color(hex: "#8b90a0")
    static let dsOutlineVariant          = Color(hex: "#414755")

    // Error
    static let dsError                   = Color(hex: "#ffb4ab")

    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - Gradient

extension LinearGradient {
    /// Signature CTA: #adc6ff → #4b8eff at 135°
    static let primaryCTA = LinearGradient(
        colors: [Color.dsPrimary, Color.dsPrimaryContainer],
        startPoint: UnitPoint(x: 0.15, y: 0.85),
        endPoint:   UnitPoint(x: 0.85, y: 0.15)
    )
}

// MARK: - Typography
// Headlines → Plus Jakarta Sans  |  Body/Labels → Inter

extension Font {
    static func dsDisplay(size: CGFloat = 56)    -> Font { .custom("PlusJakartaSans-Bold",     size: size) }
    static func dsHeadlineLg(size: CGFloat = 32) -> Font { .custom("PlusJakartaSans-SemiBold", size: size) }
    static func dsHeadlineMd(size: CGFloat = 28) -> Font { .custom("PlusJakartaSans-SemiBold", size: size) }
    static func dsHeadlineSm(size: CGFloat = 24) -> Font { .custom("PlusJakartaSans-Medium",   size: size) }
    static func dsTitleLg(size: CGFloat = 22)    -> Font { .custom("PlusJakartaSans-SemiBold", size: size) }
    static func dsTitleMd(size: CGFloat = 16)    -> Font { .custom("PlusJakartaSans-Medium",   size: size) }
    static func dsBodyLg(size: CGFloat = 16)     -> Font { .custom("Inter-Regular",            size: size) }
    static func dsBodyMd(size: CGFloat = 14)     -> Font { .custom("Inter-Regular",            size: size) }
    static func dsLabelLg(size: CGFloat = 14)    -> Font { .custom("Inter-Medium",             size: size) }
    static func dsLabelMd(size: CGFloat = 12)    -> Font { .custom("Inter-Medium",             size: size) }
    static func dsLabelSm(size: CGFloat = 11)    -> Font { .custom("Inter-Regular",            size: size) }
}

// MARK: - Spacing & Radius

enum DS {
    enum Spacing {
        static let xs:  CGFloat =  4
        static let sm:  CGFloat =  8
        static let md:  CGFloat = 16
        static let lg:  CGFloat = 24
        static let xl:  CGFloat = 32
        static let xxl: CGFloat = 48
    }
    enum Radius {
        static let sm: CGFloat =  8   // chips
        static let md: CGFloat = 12   // cards
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24   // bottom sheets
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsLabelLg())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LinearGradient.primaryCTA.opacity(configuration.isPressed ? 0.8 : 1.0))
            .cornerRadius(DS.Radius.md)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - View Helpers

/// Cross-platform corner selection (mirrors UIRectCorner semantics without UIKit).
struct CornerSet: OptionSet, Sendable {
    let rawValue: Int
    static let topLeft     = CornerSet(rawValue: 1 << 0)
    static let topRight    = CornerSet(rawValue: 1 << 1)
    static let bottomLeft  = CornerSet(rawValue: 1 << 2)
    static let bottomRight = CornerSet(rawValue: 1 << 3)
    static let top: CornerSet    = [.topLeft, .topRight]
    static let bottom: CornerSet = [.bottomLeft, .bottomRight]
    static let all: CornerSet    = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: CornerSet

    func path(in rect: CGRect) -> Path {
        // Use raw bit checks to avoid OptionSet protocol dispatch (nonisolated-safe).
        let rv = corners.rawValue
        let tl = rv & (1 << 0) != 0 ? radius : 0
        let tr = rv & (1 << 1) != 0 ? radius : 0
        let bl = rv & (1 << 2) != 0 ? radius : 0
        let br = rv & (1 << 3) != 0 ? radius : 0
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0),   clockwise: false) }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0),   endAngle: .degrees(90),  clockwise: false) }
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90),  endAngle: .degrees(180), clockwise: false) }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        p.closeSubpath()
        return p
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: CornerSet) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }

    func ghostBorder(radius: CGFloat = DS.Radius.md) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color.dsOutlineVariant.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Distance Unit

enum DistanceUnit: String, CaseIterable {
    case km    = "km"
    case miles = "miles"

    static let storageKey = "trava.distanceUnit"

    var label: String        { self == .km ? "km" : "mi" }
    var displayName: String  { self == .km ? "Kilometers" : "Miles" }

    /// Convert a stored km value to the current unit.
    func converted(_ km: Double) -> Double {
        self == .km ? km : km * 0.621371
    }

    /// Formatted string: e.g. "3.7 km" or "2.3 mi".
    func format(_ km: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f \(label)", converted(km))
    }
}

// MARK: - Navigation

enum AppTab: Int, CaseIterable {
    case exploration, dashboard, settings

    var title: String {
        switch self {
        case .exploration: return "Map"
        case .dashboard:   return "Cities"
        case .settings:    return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .exploration: return "map"
        case .dashboard:   return "building.2"
        case .settings:    return "gearshape"
        }
    }

    var activeIcon: String {
        switch self {
        case .exploration: return "map.fill"
        case .dashboard:   return "building.2.fill"
        case .settings:    return "gearshape.fill"
        }
    }
}

// MARK: - Shared Tab Bar
// Matches HTML: px-4 pb-6 pt-2, bg-[#131313]/90 backdrop-blur, rounded-t-xl
// Active tab: bg-[#2a2a2a] rounded-xl px-4 py-1 text-primary
// Inactive: text-[#909090], no background

struct DSTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        VStack(spacing: 0) {
            // Subtle 1px top border to visually separate from map content
            Rectangle()
                .fill(Color.dsSurfaceContainerHigh)
                .frame(height: 1)

            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        VStack(spacing: 0) {
                            Image(systemName: selectedTab == tab ? tab.activeIcon : tab.icon)
                                .font(.system(size: 24))
                                .foregroundColor(selectedTab == tab ? Color.dsPrimary : Color.dsOnSurfaceVariant)
                            Text(tab.title)
                                .font(.custom("Inter-Medium", size: 10))
                                .kerning(0.3)
                                .foregroundColor(selectedTab == tab ? Color.dsPrimary : Color.dsOnSurfaceVariant)
                                .padding(.top, 3)
                        }
                        .padding(.horizontal, 16)   // px-4
                        .padding(.vertical, 8)      // increased from 4 → 8pt each side
                        .background(selectedTab == tab ? Color.dsSurfaceContainerHigh : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)     // increased from 8 → 12
            .padding(.bottom, 28)  // increased from 24 → 28, sits above home indicator
        }
        .background(
            Color(hex: "#131313").opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: -2)
    }
}

// MARK: - Branded Nav Bar
// HTML: bg-[#131313] px-6 h-16, justify-between, title centered, all #adc6ff

struct DSNavBar: View {
    var trailing: AnyView = AnyView(EmptyView())

    var body: some View {
        HStack(spacing: 0) {
            // Leading placeholder to keep title centered
            Color.clear
                .frame(width: 40, height: 40)

            Text("TRAVA")
                .font(.custom("PlusJakartaSans-ExtraBold", size: 18))
                .foregroundColor(Color.dsPrimary)
                .kerning(1.8)
                .frame(maxWidth: .infinity)

            trailing
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 24)  // px-6
        .frame(height: 64)         // h-16
        .background(
            Color(hex: "#131313")
                .ignoresSafeArea(edges: .top)
        )
    }
}
