import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var hasAccess = FullDiskAccessManager.shared.hasFullDiskAccess
    @State private var openedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup guide")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Choose Scan this Mac in Overview to start a scan.")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(LocalizedStringKey(hasAccess ? "Full Disk Access granted" : "Full Disk Access is off"))
                        .font(.headline)
                } icon: {
                    Image(systemName: hasAccess ? "checkmark.shield" : "lock.shield")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if !hasAccess {
                    Text("Some protected locations are unavailable. Full Disk Access allows a more complete scan.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Privacy & Security → Full Disk Access")
                        .font(.callout)
                    HStack(spacing: 16) {
                        AppBundleDragHandle()
                        VStack(alignment: .leading, spacing: 8) {
                            Button(LocalizedStringKey(openedSettings ? "Reopen Settings" : "Open Settings & reveal PureMac"), action: openSettings)
                            if openedSettings {
                                Button("Reveal app again") { FullDiskAccessManager.shared.revealAppInFinder() }
                                Button("Reset permissions") {
                                    _ = FullDiskAccessManager.shared.resetFullDiskAccess()
                                    FullDiskAccessManager.shared.triggerRegistration()
                                    refresh()
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Divider()
            HStack {
                Button("Check again", action: refresh)
                Spacer()
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 490, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            FullDiskAccessManager.shared.triggerRegistration()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        hasAccess = FullDiskAccessManager.shared.hasFullDiskAccess
    }

    private func openSettings() {
        openedSettings = true
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            FullDiskAccessManager.shared.revealAppInFinder()
        }
    }
}
