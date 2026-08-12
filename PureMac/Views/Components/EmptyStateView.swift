import SwiftUI

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    var action: (() -> Void)?
    var actionLabel: LocalizedStringKey?
    /// Halo/icon tint — positive states pass a color (e.g. green for "All
    /// Clean"); neutral states keep the secondary look.
    var tint: Color?

    @State private var floating = false
    @State private var popped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey,
         action: (() -> Void)? = nil, actionLabel: LocalizedStringKey? = nil, tint: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.action = action
        self.actionLabel = actionLabel
        self.tint = tint
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill((tint ?? Color.secondary).opacity(0.10))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder((tint ?? Color.secondary).opacity(0.16), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint ?? Color.secondary)
            }
            // One-shot entrance pop, then a gentle idle float. Both skipped
            // under Reduce Motion.
            .scaleEffect(popped || reduceMotion ? 1 : 0.8)
            .offset(y: reduceMotion ? 0 : (floating ? -5 : 5))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    popped = true
                }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    floating = true
                }
            }

            Text(title)
                .font(.title3.bold())
                .staggered(0, baseDelay: 0.08)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .staggered(1, baseDelay: 0.08)
            if let action, let label = actionLabel {
                Button(action: action) { Text(label) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                    .staggered(2, baseDelay: 0.08)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
