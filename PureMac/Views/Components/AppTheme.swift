import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @AppStorage("PureMac.Appearance") private var rawValue = AppearanceMode.system.rawValue

    private init() {
        applyToApp()
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: rawValue) ?? .system }
        set {
            rawValue = newValue.rawValue
            objectWillChange.send()
            applyToApp()
        }
    }

    func applyToApp() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }
}

enum Tint {
    static let accent = Color(nsColor: .controlAccentColor)
    static let teal = Color(nsColor: .systemTeal)
    static let blue = Color(nsColor: .systemBlue)
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let purple = Color(nsColor: .systemPurple)
    static let pink = Color(nsColor: .systemPink)
    static let cyan = Color(nsColor: .systemCyan)
    static let red = Color(nsColor: .systemRed)
    static let yellow = Color(nsColor: .systemYellow)
}

enum MotionTokens {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.46, dampingFraction: 0.88)
    static let press = Animation.easeOut(duration: 0.1)
}

private struct InterfaceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var interfaceMotionEnabled: Bool {
        get { self[InterfaceMotionKey.self] }
        set { self[InterfaceMotionKey.self] = newValue }
    }
}

struct InterfaceMotion: ViewModifier {
    @AppStorage("settings.general.animateInterface") private var animationsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlState

    static func isEnabled(animationsEnabled: Bool, reduceMotion: Bool, windowActive: Bool) -> Bool {
        animationsEnabled && !reduceMotion && windowActive
    }

    func body(content: Content) -> some View {
        let enabled = Self.isEnabled(animationsEnabled: animationsEnabled, reduceMotion: reduceMotion,
                                     windowActive: controlState != .inactive)
        content
            .environment(\.interfaceMotionEnabled, enabled)
            .transaction { transaction in
                if !enabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

struct ToolSymbol: View {
    let systemName: String
    var tint: Color = .secondary
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.56, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

struct AmbientBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

struct ToolSection<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct StatusChip: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = Tint.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
    }
}

struct PressableScale: ViewModifier {
    @State private var hovering = false
    @State private var pressing = false
    var hoverScale: CGFloat = 1.006
    var lift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : pressing ? 0.985 : hovering ? hoverScale : 1)
            .shadow(color: .black.opacity(lift && hovering ? 0.06 : 0), radius: 10, y: 4)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .animation(reduceMotion ? nil : MotionTokens.press, value: pressing)
            .onHover { hovering = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false }
            )
    }
}

extension View {
    func pressable(hoverScale: CGFloat = 1.006, lift: Bool = false) -> some View {
        modifier(PressableScale(hoverScale: hoverScale, lift: lift))
    }
}
