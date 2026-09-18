import SwiftUI

enum AppUpdateIdentityMatcher {
    static func baseToken(_ token: String) -> String {
        let cask = token.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? token
        return cask.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? cask
    }

    static func normalizedKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    static func matchingIndex(for token: String, appNames: [String]) -> Int? {
        let key = normalizedKey(baseToken(token))
        guard !key.isEmpty else { return nil }
        let matches = appNames.indices.filter { normalizedKey(appNames[$0]) == key }
        return matches.count == 1 ? matches[0] : nil
    }

    static func fallbackDisplayName(for token: String) -> String {
        let words = baseToken(token)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? token : words.joined(separator: " ")
    }

    static func shouldShowTokenDetail(_ token: String) -> Bool {
        token.contains("@") || token.contains("/")
    }
}

@MainActor
struct AppUpdatesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updater: ApplicationUpdater
    @State private var showingUpgradeConfirmation = false
    @State private var confirmationSelection: [ManagedAppUpdate] = []

    init() {
        _updater = StateObject(wrappedValue: ApplicationUpdater())
    }

    init(updater: ApplicationUpdater) {
        _updater = StateObject(wrappedValue: updater)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    sourceCard

                    if let status = updater.statusMessage {
                        statusCard(status)
                    }

                    content
                    unmanagedAppsCard
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("App Updates")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    Label(updater.hasChecked ? String(localized: "Check Again") : String(localized: "Check for Updates"), systemImage: "arrow.clockwise")
                }
                .disabled(updater.isBusy || !updater.isHomebrewAvailable)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !updater.updates.isEmpty {
                upgradeBar
            }
        }
        .alert("Upgrade selected apps?", isPresented: $showingUpgradeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(upgradeConfirmationLabel(count: confirmationSelection.count)) {
                let selection = confirmationSelection
                Task { await updater.upgrade(selection) }
            }
        } message: {
            Text(upgradeConfirmationMessage)
        }
        .onAppear {
            updater.refreshAvailability()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(systemName: "arrow.down.app.fill", tint: Tint.accent, size: 48, corner: 13, vivid: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("App Updates")
                    .font(.system(size: 25, weight: .bold))
                Text("Review and update apps installed as Homebrew casks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let date = updater.lastCheckedAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last checked")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(date, style: .relative)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceCard: some View {
        CardSurface(padding: 16, elevation: .flat, tint: Tint.accent) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: "shippingbox.fill", tint: Tint.accent, size: 32, corner: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updates from Homebrew")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Checking asks Homebrew to refresh its package data as needed and contacts Homebrew's configured sources. PureMac only lists cask apps managed by this Homebrew installation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !updater.isHomebrewAvailable {
            stateCard(
                title: "Homebrew not found",
                message: "Install Homebrew to check cask apps here. Apps from the App Store and direct downloads use their own update channels.",
                systemImage: "shippingbox",
                tint: Tint.orange
            )
        } else if updater.isChecking {
            CardSurface(padding: 28, elevation: .standard) {
                HStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Checking Homebrew casks")
                            .font(.headline)
                        Text("Refreshing package data and comparing installed versions.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else if let error = updater.errorMessage {
            CardSurface(padding: 22, elevation: .standard, tint: Tint.red) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemName: "exclamationmark.triangle.fill", tint: Tint.red, size: 36, corner: 10)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Couldn't check for updates")
                            .font(.headline)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Try Again") {
                            Task { await updater.checkForUpdates() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(updater.isBusy)
                    }
                    Spacer()
                }
            }
        } else if updater.hasChecked && updater.updates.isEmpty {
            stateCard(
                title: "Homebrew apps are up to date",
                message: "No updates are currently available for the cask apps Homebrew manages.",
                systemImage: "checkmark.circle.fill",
                tint: Tint.green
            )
        } else if updater.updates.isEmpty {
            CardSurface(padding: 28, elevation: .standard) {
                VStack(spacing: 14) {
                    IconTile(systemName: "arrow.triangle.2.circlepath", tint: Tint.accent, size: 48, corner: 13)
                    Text("Check installed cask apps")
                        .font(.title3.weight(.semibold))
                    Text("PureMac will ask Homebrew for available versions when you start the check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Check for Updates") {
                        Task { await updater.checkForUpdates() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else {
            updatesCard
        }
    }

    private var updatesCard: some View {
        CardSurface(padding: 0, elevation: .standard) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateCountTitle)
                            .font(.headline)
                        Text("Select the apps Homebrew should upgrade.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)

                Divider()

                LazyVStack(spacing: 0) {
                    ForEach(Array(updater.updates.enumerated()), id: \.element.id) { index, update in
                        updateRow(update)
                        if index < updater.updates.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func updateRow(_ update: ManagedAppUpdate) -> some View {
        let app = installedApp(for: update.token)
        let presentation = updater.caskPresentations[update.token]
        let displayName = app?.appName
            ?? presentation?.displayName
            ?? AppUpdateIdentityMatcher.fallbackDisplayName(for: update.token)

        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { updater.selectedTokens.contains(update.token) },
                set: { updater.setSelected($0, token: update.token) }
            ))
            .labelsHidden()
            .toggleStyle(AnimatedCheckboxStyle(tint: Tint.accent))
            .disabled(update.isPinned || updater.isBusy)
            .accessibilityLabel("Select \(displayName)")

            appIcon(app?.icon ?? presentation?.icon, isPinned: update.isPinned)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if update.isPinned {
                        StatusChip(label: String(localized: "Pinned"), systemImage: "pin.fill", tint: Tint.orange)
                    }
                }
                Text(updateDetail(update))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if presentation?.isBundleMissing == true {
                    Text("App bundle missing")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Tint.orange)
                }
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 3) {
                Text("Available")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(update.currentVersion)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func appIcon(_ icon: NSImage?, isPinned: Bool) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            IconTile(systemName: "app.fill", tint: isPinned ? Tint.orange : Tint.accent, size: 32, corner: 8)
        }
    }

    private func installedApp(for token: String) -> InstalledApp? {
        let names = appState.installedApps.map(\.appName)
        guard let index = AppUpdateIdentityMatcher.matchingIndex(for: token, appNames: names) else { return nil }
        return appState.installedApps[index]
    }

    private func displayName(for token: String) -> String {
        installedApp(for: token)?.appName
            ?? updater.caskPresentations[token]?.displayName
            ?? AppUpdateIdentityMatcher.fallbackDisplayName(for: token)
    }

    private func updateDetail(_ update: ManagedAppUpdate) -> String {
        let installed = String(localized: "Installed \(update.installedVersion)")
        guard AppUpdateIdentityMatcher.shouldShowTokenDetail(update.token) else { return installed }
        return "\(update.token)  ·  \(installed)"
    }

    private var unmanagedAppsCard: some View {
        CardSurface(padding: 16, elevation: .flat) {
            HStack(spacing: 12) {
                IconTile(systemName: "storefront.fill", tint: Tint.blue, size: 32, corner: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps outside Homebrew")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Open the App Store updates page. Direct-download apps may provide their own updater.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open App Store Updates") {
                    updater.openAppStoreUpdates()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func stateCard(title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        CardSurface(padding: 28, elevation: .standard, tint: tint) {
            VStack(spacing: 12) {
                IconTile(systemName: systemImage, tint: tint, size: 48, corner: 13)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func statusCard(_ status: String) -> some View {
        CardSurface(padding: 14, elevation: .flat, tint: Tint.green) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tint.green)
                Text(status)
                    .font(.callout.weight(.medium))
                Spacer()
            }
        }
    }

    private var upgradeBar: some View {
        HStack {
            Text(updater.selectedCount == 0 ? String(localized: "Select apps to update") : selectedCountTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(updater.selectedCount == 0 ? Color.secondary : Color.primary)
            Spacer()
            Button {
                confirmationSelection = updater.updates.filter {
                    updater.selectedTokens.contains($0.token) && !$0.isPinned
                }
                showingUpgradeConfirmation = true
            } label: {
                if updater.isUpgrading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating…")
                    }
                } else {
                    Text(upgradeConfirmationLabel(count: updater.selectedCount))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.accent)
            .disabled(updater.selectedCount == 0 || updater.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var updateCountTitle: String {
        updater.updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(updater.updates.count) updates available")
    }

    private var selectedCountTitle: String {
        updater.selectedCount == 1 ? String(localized: "1 app selected") : String(localized: "\(updater.selectedCount) apps selected")
    }

    private func upgradeConfirmationLabel(count: Int) -> String {
        count == 1 ? String(localized: "Upgrade 1 App") : String(localized: "Upgrade \(count) Apps")
    }

    private var upgradeConfirmationMessage: String {
        let versions = confirmationSelection.map {
            String(localized: "\(displayName(for: $0.token)) \($0.installedVersion) to \($0.currentVersion)")
        }
        let selectionSummary: String
        if versions.count <= 5 {
            selectionSummary = versions.joined(separator: ", ")
        } else {
            selectionSummary = versions.prefix(5).joined(separator: ", ") + String(localized: ", and \(versions.count - 5) more")
        }
        return String(localized: "Homebrew will upgrade \(selectionSummary). It may quit running apps and remove superseded cask versions as part of its normal upgrade process.")
    }
}
