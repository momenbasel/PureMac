import SwiftUI

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    var action: (() -> Void)?
    var actionLabel: LocalizedStringKey?

    init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey, action: (() -> Void)? = nil, actionLabel: LocalizedStringKey? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.action = action
        self.actionLabel = actionLabel
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let action, let label = actionLabel {
                Button(label, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
