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

/// Centralized accent palette. Keeping these in one place lets the dashboard
/// and sidebar share semantic tints (cleanup orange, performance green, etc.)
/// instead of scattered Color literals.
enum Tint {
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let green  = Color(red: 0.18, green: 0.78, blue: 0.47)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    static let pink   = Color(red: 1.00, green: 0.30, blue: 0.50)
    static let cyan   = Color(red: 0.30, green: 0.80, blue: 0.95)
    static let red    = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let yellow = Color(red: 1.00, green: 0.78, blue: 0.04)
}

/// Tinted square icon container used in the sidebar and on dashboard cards.
/// The optional inner gradient + soft shadow give the tile depth rather than
/// the previous flat color swatch.
struct IconTile: View {
    let systemName: String
    var tint: Color = Tint.blue
    var size: CGFloat = 26
    var corner: CGFloat = 7
    var glow: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .shadow(color: glow ? tint.opacity(0.35) : .clear, radius: glow ? 6 : 0, y: 1)
    }
}

/// Premium card surface used on the dashboard, suggestion list, and detail
/// pages. Inner gradient fill + dual-layer shadow (ambient + contact) gives
/// the cards depth without dropping into heavy material that fights the
/// system look. Optional accent stripe lights up the leading edge so cards
/// can carry semantic colour without painting the whole surface.
struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    var accent: Color? = nil
    var elevation: CardElevation = .standard
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.04),
                                    Color.clear,
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    if let accent {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [accent.opacity(0.85), accent.opacity(0.35)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .frame(width: 3)
                            Spacer(minLength: 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(elevation.ambient), radius: elevation.ambientRadius, y: elevation.ambientY)
            .shadow(color: .black.opacity(elevation.contact), radius: 1, y: 0.5)
    }
}

enum CardElevation {
    case flat, standard, raised

    var ambient: Double {
        switch self {
        case .flat: return 0.02
        case .standard: return 0.06
        case .raised: return 0.10
        }
    }

    var ambientRadius: CGFloat {
        switch self {
        case .flat: return 2
        case .standard: return 6
        case .raised: return 14
        }
    }

    var ambientY: CGFloat {
        switch self {
        case .flat: return 1
        case .standard: return 2
        case .raised: return 6
        }
    }

    var contact: Double { 0.05 }
}

/// Pill-shaped chip used for inline status pills (severity, counts, etc.).
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
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        )
        .foregroundStyle(tint)
    }
}

/// Modifier that bumps an element on hover and shrinks it on press. Cheap way
/// to give cards and rows a tactile feel without writing per-call animations.
struct PressableScale: ViewModifier {
    @State private var hovering = false
    @State private var pressing = false
    var hoverScale: CGFloat = 1.012

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressing ? 0.985 : (hovering ? hoverScale : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressing)
            .onHover { hovering = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false }
            )
    }
}

extension View {
    func pressable(hoverScale: CGFloat = 1.012) -> some View {
        modifier(PressableScale(hoverScale: hoverScale))
    }
}
