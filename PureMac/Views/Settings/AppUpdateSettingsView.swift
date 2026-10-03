import AppKit
import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject private var updater = UpdateService.shared
    @AppStorage("settings.updates.installationMethod") private var installationMethod = "download"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep PureMac up to date")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Checks the official app releases on GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if updater.isChecking { ProgressView().controlSize(.small) }
                Button("Check for Updates") { updater.checkForUpdates() }
                    .disabled(updater.isChecking)
                    .accessibilityIdentifier("settings.checkForUpdates")
            }

            status

            if let checked = updater.lastChecked {
                Text(String(format: String(localized: "Last checked: %@"), checked.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Picker("Update method", selection: $installationMethod) {
                Text("Download (DMG / ZIP)").tag("download")
                Text("Homebrew").tag("homebrew")
            }
            if installationMethod == "homebrew" {
                Text("To update with Homebrew, run this command in Terminal. The cask may follow the GitHub release a little later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("brew update && brew upgrade --cask puremac")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew update && brew upgrade --cask puremac", forType: .string)
                    }
                }
            } else {
                Text("Download the new app from the release page, quit PureMac, then replace it in Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Link("View releases", destination: UpdateService.releasesURL)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: String(localized: "PureMac %@ is available"), release.tagName), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Tint.accent)
                Link("Open release page", destination: release.htmlURL)
            }
        case .upToDate:
            Label("You're using the latest available version of PureMac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tint.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
