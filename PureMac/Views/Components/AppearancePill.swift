import SwiftUI

/// Inline 3-segment toggle (system / light / dark) with an animated active
/// indicator that slides between segments. Replaces the SwiftUI `Menu` which
/// looked like a generic dropdown affordance.
struct AppearancePill: View {
    @Binding var selection: AppearanceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private static let segmentWidth: CGFloat = 28
    private static let segmentHeight: CGFloat = 22
    private static let segmentSpacing: CGFloat = 2

    private var selectedIndex: CGFloat {
        CGFloat(AppearanceMode.allCases.firstIndex(of: selection) ?? 0)
    }

    var body: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = mode
                    }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                        .foregroundStyle(selection == mode ? Color.primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey(mode.label))
            }
        }
        // Indicator is anchored to the pill's own bounds and positioned by
        // segment index, so toolbar re-layout can't misplace it. The previous
        // matchedGeometryEffect resolved a zero frame inside the NSToolbar
        // hosting view and drew the highlight at the window origin (#127).
        // .offset(x:) is not layout-direction aware, so mirror it for RTL.
        .background(alignment: .leading) {
            let x = selectedIndex * (Self.segmentWidth + Self.segmentSpacing)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                .offset(x: layoutDirection == .rightToLeft ? -x : x)
        }
    }
}
