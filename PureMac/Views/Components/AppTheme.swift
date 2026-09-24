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
    static let accent = Color(red: 0.08, green: 0.58, blue: 0.54)
    static let teal = accent
    static let blue = Color(red: 0.18, green: 0.48, blue: 0.88)
    static let green = Color(red: 0.18, green: 0.65, blue: 0.43)
    static let orange = Color(red: 0.92, green: 0.52, blue: 0.16)
    static let purple = Color(red: 0.49, green: 0.38, blue: 0.72)
    static let pink = Color(red: 0.82, green: 0.34, blue: 0.49)
    static let cyan = Color(red: 0.19, green: 0.63, blue: 0.72)
    static let red = Color(red: 0.85, green: 0.25, blue: 0.24)
    static let yellow = Color(red: 0.87, green: 0.68, blue: 0.16)
}

enum MotionTokens {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.46, dampingFraction: 0.88)
    static let press = Animation.easeOut(duration: 0.1)
}

enum TintGradient {
    static let accent = LinearGradient(
        colors: [Tint.accent, Tint.accent.opacity(0.86)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let smartCare = LinearGradient(
        colors: [
            Color(red: 0.075, green: 0.085, blue: 0.09),
            Color(red: 0.045, green: 0.052, blue: 0.055)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let destructive = LinearGradient(
        colors: [Tint.red, Tint.red.opacity(0.86)],
        startPoint: .top,
        endPoint: .bottom
    )

    static func of(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }
}

struct IconTile: View {
    let systemName: String
    var tint: Color = Tint.accent
    var size: CGFloat = 26
    var corner: CGFloat = 7
    var glow = false
    var vivid = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(vivid ? tint : tint.opacity(glow ? 0.20 : 0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(tint.opacity(vivid ? 0.22 : 0.16), lineWidth: 0.5)
                }
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(vivid ? Color.white : tint)
        }
        .frame(width: size, height: size)
    }
}

struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.018) : Color.black.opacity(0.014))
                .frame(height: 96)
        }
        .ignoresSafeArea()
    }
}

struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    var accent: Color? = nil
    var elevation: CardElevation = .standard
    var material: Material? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 14

    var body: some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    if let material {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(material)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.035))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                if let accent {
                    Capsule()
                        .fill(accent.opacity(0.72))
                        .frame(width: 36, height: 2)
                        .padding(.top, 1)
                }
            }
            .shadow(
                color: .black.opacity(elevation.ambient),
                radius: elevation.ambientRadius,
                y: elevation.ambientY
            )
    }
}

enum CardElevation {
    case flat, standard, raised

    var ambient: Double {
        switch self {
        case .flat: return 0
        case .standard: return 0.035
        case .raised: return 0.07
        }
    }

    var ambientRadius: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 6
        case .raised: return 16
        }
    }

    var ambientY: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 2
        case .raised: return 7
        }
    }
}

struct StatusChip: View {
    let label: Text
    var systemImage: String? = nil
    var tint: Color = Tint.accent

    init(label: LocalizedStringKey, systemImage: String? = nil, tint: Color = Tint.accent) {
        self.label = Text(label)
        self.systemImage = systemImage
        self.tint = tint
    }

    init(verbatimLabel: String, systemImage: String? = nil, tint: Color = Tint.accent) {
        self.label = Text(verbatim: verbatimLabel)
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            label
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.11)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.15), lineWidth: 0.5))
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

struct GlowProminentButtonStyle: ButtonStyle {
    var tint: Color = Tint.accent
    var gradient: LinearGradient = TintGradient.accent
    var breathes = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 20 : 16)
            .padding(.vertical, large ? 10 : 8)
            .background(Capsule().fill(gradient))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}

struct AnimatedCheckboxStyle: ToggleStyle {
    var tint: Color = Tint.accent

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? tint : Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(configuration.isOn ? tint : Color.primary.opacity(0.24), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(configuration.isOn ? 1 : 0)
            }
            .frame(width: 15, height: 15)
            configuration.label
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}
