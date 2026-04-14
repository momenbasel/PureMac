import SwiftUI
import AppKit

// MARK: - NSColor Hex Support

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

// MARK: - Color Theme

extension Color {
    // Adaptive color helper
    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }

    // Background colors
    static let pmBackground = adaptive(light: "F5F5F7", dark: "1C1C1E")
    static let pmSidebar = adaptive(light: "EEEEF0", dark: "2C2C2E")
    static let pmCard = adaptive(light: "FFFFFF", dark: "3A3A3C")
    static let pmCardHover = adaptive(light: "F0F0F2", dark: "48484A")

    // Accent colors
    static let pmAccent = adaptive(light: "4F46E5", dark: "6366F1")
    static let pmAccentLight = adaptive(light: "6366F1", dark: "818CF8")
    static let pmAccentDark = adaptive(light: "3730A3", dark: "4F46E5")

    // Gradient colors
    static let pmGradientStart = adaptive(light: "4F46E5", dark: "6366F1")
    static let pmGradientEnd = adaptive(light: "7C3AED", dark: "A855F7")

    // Status colors
    static let pmSuccess = adaptive(light: "34C759", dark: "30D158")
    static let pmWarning = adaptive(light: "FF9F0A", dark: "FF9F0A")
    static let pmDanger = adaptive(light: "FF3B30", dark: "FF453A")
    static let pmInfo = adaptive(light: "007AFF", dark: "0A84FF")

    // Text colors
    static let pmTextPrimary = adaptive(light: "1D1D1F", dark: "F5F5F7")
    static let pmTextSecondary = adaptive(light: "6E6E73", dark: "98989D")
    static let pmTextMuted = adaptive(light: "AEAEB2", dark: "636366")

    // Separator
    static let pmSeparator = adaptive(light: "D1D1D6", dark: "38383A")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Gradients

struct AppGradients {
    static let primary = LinearGradient(
        colors: [.pmGradientStart, .pmGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accent = LinearGradient(
        colors: [.pmAccent, .pmGradientEnd],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let danger = LinearGradient(
        colors: [.pmDanger, .pmDanger.opacity(0.85)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let success = LinearGradient(
        colors: [.pmSuccess, .pmSuccess.opacity(0.85)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let scanRing = AngularGradient(
        colors: [.pmAccent, .pmAccentLight, .pmAccent],
        center: .center
    )
}

// MARK: - Shadows

extension View {
    func pmShadow(radius: CGFloat = 10, y: CGFloat = 4) -> some View {
        self.shadow(color: .black.opacity(0.15), radius: radius, x: 0, y: y)
    }

    func pmGlow(color: Color = .pmAccent, radius: CGFloat = 8) -> some View {
        self.shadow(color: color.opacity(0.15), radius: radius, x: 0, y: 0)
    }
}

// MARK: - Text Styles

extension Font {
    static let pmTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let pmHeadline = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let pmSubheadline = Font.system(size: 16, weight: .medium, design: .rounded)
    static let pmBody = Font.system(size: 14, weight: .regular, design: .rounded)
    static let pmCaption = Font.system(size: 12, weight: .medium, design: .rounded)
    static let pmLargeNumber = Font.system(size: 42, weight: .bold, design: .rounded)
    static let pmMediumNumber = Font.system(size: 24, weight: .bold, design: .rounded)
}

// MARK: - Animation

extension Animation {
    static let pmSpring = Animation.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)
    static let pmSmooth = Animation.easeInOut(duration: 0.3)
    static let pmSlow = Animation.easeInOut(duration: 0.6)
}
