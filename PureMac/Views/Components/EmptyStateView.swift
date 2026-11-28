import SwiftUI

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    var action: (() -> Void)?
    var actionLabel: LocalizedStringKey?
    var tint: Color?

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
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(tint ?? Color.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let action, let label = actionLabel {
                Button(action: action) { Text(label) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
