import SwiftUI

/// User-overridable appearance setting that lives independently of the system
/// preference, mirroring the prototype's titlebar light/dark toggle.
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @AppStorage("PureMac.Appearance") private var rawValue: String = AppearanceMode.system.rawValue

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: rawValue) ?? .system }
        set { rawValue = newValue.rawValue; objectWillChange.send() }
    }
}

/// Centralized accent palette. One blue, one green for success, one orange
/// for warning, one red for destructive. Other tints exist for categorical
/// differentiation but the surface chrome only uses these four.
enum Tint {
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let green  = Color(red: 0.18, green: 0.78, blue: 0.47)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.04)
    static let purple = Color(red: 0.55, green: 0.32, blue: 0.87)
    static let pink   = Color(red: 1.00, green: 0.30, blue: 0.50)
    static let cyan   = Color(red: 0.30, green: 0.78, blue: 0.95)
    static let red    = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let yellow = Color(red: 1.00, green: 0.78, blue: 0.04)
}

/// Shared animation vocabulary so every surface moves with the same feel.
/// Hover/selection feedback uses `snappy`, entrances and state swaps use
/// `gentle`, press acknowledgment uses `press`.
enum MotionTokens {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let press  = Animation.easeOut(duration: 0.12)
}

/// Gradient pairs built from the flat `Tint` palette. Reserved for primary
/// CTAs and focal chrome — secondary surfaces stay flat.
enum TintGradient {
    static let accent = LinearGradient(
        colors: [Tint.blue, Tint.purple],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let destructive = LinearGradient(
        colors: [Tint.red, Tint.red.opacity(0.8)],
        startPoint: .top, endPoint: .bottom
    )
    static func of(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .top, endPoint: .bottom)
    }
}

/// Tinted square icon container used in the sidebar and on dashboard cards.
/// Two-stop tinted fill with a hairline inner stroke. When `glow` is set
/// (selected sidebar row, emphasized card) the tile picks up a stronger
/// gradient and a soft tinted halo. When `vivid` is set the tile becomes a
/// full-saturation gradient bubble with a white glyph — reserved for focal
/// spots (category heroes, result rows) so the chrome stays matte elsewhere.
struct IconTile: View {
    let systemName: String
    var tint: Color = Tint.blue
    var size: CGFloat = 26
    var corner: CGFloat = 7
    var glow: Bool = false
    var vivid: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: vivid
                            ? [tint, tint.opacity(0.72)]
                            : [tint.opacity(glow ? 0.32 : 0.16), tint.opacity(glow ? 0.16 : 0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(vivid ? Color.white.opacity(0.22) : tint.opacity(glow ? 0.38 : 0.20),
                                      lineWidth: 0.5)
                )
                .shadow(color: tint.opacity(vivid ? 0.42 : (glow ? 0.45 : 0)),
                        radius: vivid ? 6 : (glow ? 5 : 0))
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(vivid ? Color.white : tint)
                .shadow(color: vivid ? Color.black.opacity(0.18) : tint.opacity(glow ? 0.5 : 0),
                        radius: vivid ? 2 : (glow ? 3 : 0))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: glow)
    }
}

/// Shared ambient backdrop for the app's detail surfaces: layered radial
/// washes in jewel tones, concentrated at the top where hero content lives
/// and fading to nothing at the bottom. Static layers — no Reduce Motion
/// concerns. Opacities halve in light mode so surfaces stay clean.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private var strength: Double { colorScheme == .dark ? 1 : 0.55 }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Tint.blue.opacity(0.10 * strength), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            RadialGradient(
                colors: [Tint.purple.opacity(0.08 * strength), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 620
            )
            RadialGradient(
                colors: [Tint.pink.opacity(0.05 * strength), .clear],
                center: UnitPoint(x: 0.5, y: -0.15), startRadius: 0, endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

/// Card surface. Flat fill, hairline border, soft shadow. No accent stripe —
/// content hierarchy carries the meaning, not chrome. Pass `material` for a
/// vibrancy/glass panel (used on focal hero states where a tinted backdrop
/// sits behind the card). Pass `tint` for a barely-there vertical color wash
/// that gives the card an identity without adding chrome.
struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    /// Retained for callsite compatibility; the accent line is intentionally
    /// not rendered in the restrained design.
    var accent: Color? = nil
    var elevation: CardElevation = .standard
    var material: Material? = nil
    /// Optional identity wash. Kept under ~7% opacity so text contrast and
    /// light-mode cleanliness are unaffected.
    var tint: Color? = nil
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 14

    var body: some View {
        content
            .padding(padding)
            .background(
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
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.07), tint.opacity(0.015)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        material != nil ? Color.white.opacity(0.14) : Color.primary.opacity(0.07),
                        lineWidth: material != nil ? 1 : 0.5
                    )
            )
            .shadow(color: .black.opacity(elevation.ambient), radius: elevation.ambientRadius, y: elevation.ambientY)
    }
}

enum CardElevation {
    case flat, standard, raised

    var ambient: Double {
        switch self {
        case .flat: return 0.0
        case .standard: return 0.05
        case .raised: return 0.10
        }
    }

    var ambientRadius: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 7
        case .raised: return 20
        }
    }

    var ambientY: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 2
        case .raised: return 8
        }
    }
}

/// Small status pill. Solid tint background at low opacity, no gradient.
struct StatusChip: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = Tint.blue

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
}

/// Consistent section title used on dashboard-style surfaces. Single source
/// of truth for the "quiet bold headline" look so every section matches.
struct SectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
    }
}

/// Hover/press feedback for tappable cards. Plain mode is a subtle scale;
/// `lift` mode adds the CleanMyMac-style float (rise + soft shadow). Under
/// Reduce Motion the scale/offset are dropped and only the shadow remains.
struct PressableScale: ViewModifier {
    @State private var hovering = false
    @State private var pressing = false
    var hoverScale: CGFloat = 1.006
    var lift: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1.0 : (pressing ? 0.97 : (hovering ? (lift ? 1.02 : hoverScale) : 1.0)))
            .offset(y: lift && hovering && !reduceMotion ? -2 : 0)
            .shadow(color: .black.opacity(lift && hovering ? 0.12 : 0),
                    radius: lift && hovering ? 14 : 0,
                    y: lift && hovering ? 6 : 0)
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

/// Gradient capsule CTA with a soft tinted glow — the primary-action style.
/// Hover lifts the glow and scale; press squeezes. `breathes` adds a gentle
/// idle glow pulse (radius only, no scale) for the single hero CTA on an
/// otherwise calm screen. `large` bumps the type and padding for the one
/// dominant call-to-action on a surface. All motion is suppressed under
/// Reduce Motion.
struct GlowProminentButtonStyle: ButtonStyle {
    var tint: Color = Tint.blue
    var gradient: LinearGradient = TintGradient.accent
    var breathes: Bool = false
    var large: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GlowBody(configuration: configuration, tint: tint, gradient: gradient,
                 breathes: breathes, large: large)
    }

    private struct GlowBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let gradient: LinearGradient
        let breathes: Bool
        let large: Bool

        @State private var hovering = false
        @State private var breathe = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 22 : 18)
                .padding(.vertical, large ? 11 : 9)
                .background(Capsule().fill(gradient))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: tint.opacity(hovering ? 0.45 : (breathe ? 0.40 : 0.22)),
                        radius: hovering ? 14 : (breathe ? 12 : 7), y: 3)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1)))
                .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
                .animation(reduceMotion ? nil : MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .onAppear {
                    guard breathes, !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }
        }
    }
}

/// Checkbox replacement with a springy check pop. Visually matches the size
/// of the native control so adopting it doesn't shift row layout. Keeps the
/// native checkbox's accessibility semantics (role, checked value, Space-key
/// toggling, VoiceOver) via accessibilityRepresentation so swapping it in
/// doesn't regress keyboard/screen-reader users.
struct AnimatedCheckboxStyle: ToggleStyle {
    var tint: Color = Tint.blue

    func makeBody(configuration: Configuration) -> some View {
        CheckBody(configuration: configuration, tint: tint)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.checkbox)
            }
    }

    private struct CheckBody: View {
        let configuration: ToggleStyleConfiguration
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(configuration.isOn ? tint : Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(configuration.isOn ? tint : Color.primary.opacity(0.25), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(configuration.isOn ? 1 : 0.3)
                        .opacity(configuration.isOn ? 1 : 0)
                }
                .frame(width: 15, height: 15)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isOn)

                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
