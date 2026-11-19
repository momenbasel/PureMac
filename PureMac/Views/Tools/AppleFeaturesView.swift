import AppKit
import SwiftUI

struct AppleFeaturesView: View {
    @EnvironmentObject private var appState: AppState
    private enum Page: String, CaseIterable {
        case features = "Features"
        case storage = "Storage"
    }

    private struct BackupSelection: Identifiable {
        let id = UUID()
        let backups: [DeviceBackup]
    }

    private let version = ProcessInfo.processInfo.operatingSystemVersion
    @State private var page = Page.features
    @State private var search = ""
    @State private var inventory: [AppleStorageItem]?
    @State private var inventoryTask: Task<Void, Never>?
    @State private var inventoryRunning = false
    @State private var inventoryNotice: String?
    @State private var backupService = DeviceBackupService()
    @State private var backups: [DeviceBackup] = []
    @State private var backupIssues: [String] = []
    @State private var backupSelection: Set<URL> = []
    @State private var backupTask: Task<Void, Never>?
    @State private var backupsRunning = false
    @State private var backupsScanned = false
    @State private var removalTask: Task<Void, Never>?
    @State private var removalNotice: String?
    @State private var pendingRemoval: BackupSelection?
    @State private var errorMessage: String?

    private var removalRunning: Bool { appState.deviceBackupRemovalInProgress }

    private var features: [AppleFeature] {
        AppleFeatureCatalog.features(for: version).filter {
            search.isEmpty || "\($0.title) \($0.summary) \($0.steps)".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Features")
                        .font(.system(size: 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Review optional features and the storage used by Apple downloads.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Picker("Apple Features section", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { page in
                        Text(LocalizedStringKey(page.rawValue)).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(removalRunning)

                if removalRunning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finishing backup removal. New scans are available when it stops.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if let result = appState.deviceBackupRemovalResult {
                    DeviceBackupRemovalReport(result: result) {
                        appState.deviceBackupRemovalResult = nil
                    }
                }

                if page == .features {
                    featuresContent
                } else {
                    storageContent
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Apple Features")
        .alert("Couldn't complete the action", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $pendingRemoval) { selection in
            DeviceBackupConfirmation(backups: selection.backups, canRemove: appState.canRemoveDeviceBackups) {
                pendingRemoval = nil
                removeBackups(selection.backups)
            }
        }
        .onDisappear {
            inventoryTask?.cancel()
            backupTask?.cancel()
            removalTask?.cancel()
        }
    }

    private var featuresContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Changes are made in Apple's settings. PureMac does not detect or verify whether a feature is enabled.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a feature", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("appleFeatures.search")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))

            if features.isEmpty {
                Text("No features match your search.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                            AppleFeatureRow(feature: feature, version: version, openDestination: openDestination, openGuide: openURL)
                            if index < features.count - 1 { Divider() }
                        }
                    }
                }
            }

            Text("Availability also depends on your Mac model, language, region, account, and device management. Apple Intelligence requires a supported Mac with Apple silicon. Setting names can vary between macOS versions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple downloads")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Measure known locations without deleting files. These sizes are not a recoverable-space estimate.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(inventory == nil ? "Measure storage" : "Measure again", action: scanInventory)
                    .buttonStyle(.bordered)
                    .disabled(inventoryRunning || removalRunning)
                    .accessibilityIdentifier("appleFeatures.measureStorage")
            }

            if inventoryRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring Apple storage…")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Stop") { inventoryTask?.cancel() }
                        .buttonStyle(.borderless)
                }
            }
            if let inventoryNotice {
                Text(inventoryNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let inventory {
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(inventory.enumerated()), id: \.element.id) { index, item in
                            AppleStorageRow(item: item, reveal: reveal, openDestination: openDestination)
                            if index < inventory.count - 1 { Divider() }
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                Button("Storage settings") { openDestination("com.apple.settings.Storage") }
                Button("Wallpaper settings") { openDestination("com.apple.Wallpaper-Settings.extension") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))

            Divider()
            backupContent
        }
    }

    private var backupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("iPhone and iPad backups")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Review complete local backups individually. Selected backups move to the Trash after confirmation.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(backupsScanned ? "Scan again" : "Find backups", action: scanBackups)
                    .buttonStyle(.bordered)
                    .disabled(backupsRunning || removalRunning)
                    .accessibilityIdentifier("appleFeatures.findBackups")
            }
            if backupsRunning || removalRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(removalRunning ? "Checking and moving selected backups to the Trash…" : "Checking local backups…")
                        .font(.system(size: 12))
                    Spacer()
                    if backupsRunning {
                        Button("Stop") { backupTask?.cancel() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if let removalNotice {
                Text(removalNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if appState.scanState.isActive {
                Text("Backup removal is available after the current scan or cleanup finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if !backupIssues.isEmpty {
                DisclosureGroup("\(backupIssues.count) backup locations could not be included") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(backupIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
                .font(.system(size: 12))
            }
            if backupsScanned && backups.isEmpty && !backupsRunning {
                Text(backupIssues.isEmpty ? "No complete local device backups were found." : "No backups are available to select. Review the scan issues above.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if !backups.isEmpty {
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                            backupRow(backup)
                            if index < backups.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                }
                .disabled(backupsRunning || removalRunning)

                HStack {
                    Text("\(backupSelection.count) selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review selected backups") {
                        let selection = backups.filter { backupSelection.contains($0.id) }
                        if !selection.isEmpty { pendingRemoval = BackupSelection(backups: selection) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(backupSelection.isEmpty || backupsRunning || !appState.canRemoveDeviceBackups)
                }
            }
        }
    }

    private func backupRow(_ backup: DeviceBackup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select backup \(backup.name)", isOn: Binding(
                get: { backupSelection.contains(backup.id) },
                set: { selected in
                    if selected { backupSelection.insert(backup.id) }
                    else { backupSelection.remove(backup.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.name)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                Text(backup.url.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Modified \(backup.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteCountFormatter.string(fromByteCount: backup.allocatedSize, countStyle: .file))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Button("Show in Finder") { reveal(backup.url) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        .padding(14)
    }

    @MainActor
    private func scanInventory() {
        guard !inventoryRunning, !removalRunning else { return }
        inventoryRunning = true
        inventoryNotice = nil
        inventoryTask = Task { @MainActor in
            defer { inventoryRunning = false }
            do {
                let result = try await AppleStorageService.scan()
                try Task.checkCancellation()
                inventory = result
            } catch is CancellationError {
                inventoryNotice = inventory == nil ? "Storage measurement stopped." : "Storage measurement stopped. Previous results are still shown."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func scanBackups() {
        guard !backupsRunning, !removalRunning else { return }
        backupsRunning = true
        backupsScanned = false
        backups = []
        backupIssues = []
        backupSelection = []
        removalNotice = nil
        backupTask = Task { @MainActor in
            defer { backupsRunning = false }
            do {
                let result = try await backupService.scan()
                try Task.checkCancellation()
                backups = result.backups
                backupIssues = result.issues
                backupsScanned = true
            } catch is CancellationError {
                removalNotice = "Backup scan stopped. Scan again before selecting backups."
                backups = []
                backupsScanned = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func removeBackups(_ selection: [DeviceBackup]) {
        guard !backupsRunning else { return }
        guard appState.canRemoveDeviceBackups else {
            removalNotice = "Backup removal is available after the current scan or cleanup finishes."
            return
        }
        let sharedState = appState
        sharedState.deviceBackupRemovalInProgress = true
        sharedState.deviceBackupRemovalResult = nil
        removalNotice = nil
        inventoryTask?.cancel()
        removalTask = Task { @MainActor in
            defer { sharedState.deviceBackupRemovalInProgress = false }
            do {
                let result = try await backupService.trash(selection)
                sharedState.deviceBackupRemovalResult = result
                let removed = Set(result.removedPaths)
                backups.removeAll { removed.contains($0.url.path) }
                backupSelection = []
                if !removed.isEmpty {
                    inventory = nil
                    inventoryNotice = "Backups changed. Measure storage again for current sizes."
                }
            } catch {
                sharedState.deviceBackupRemovalResult = DeviceBackupRemovalResult(
                    removedPaths: [], errors: [error.localizedDescription]
                )
            }
        }
    }

    private func openDestination(_ destination: String) {
        if destination.hasPrefix("application:") {
            let identifier = String(destination.dropFirst("application:".count))
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                errorMessage = "The app could not be found. Open it manually and follow the steps shown."
                return
            }
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:\(destination)") {
            if !NSWorkspace.shared.open(url) {
                let fallback = URL(fileURLWithPath: "/System/Applications/System Settings.app")
                let opened = NSWorkspace.shared.open(fallback)
                errorMessage = opened
                    ? "The settings shortcut could not be opened. System Settings is open; follow the steps shown to find the control."
                    : "System Settings could not be opened. Open it from the Apple menu and follow the steps shown."
            }
        } else {
            errorMessage = "The settings shortcut is unavailable. Open System Settings from the Apple menu."
        }
    }

    private func openURL(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            errorMessage = "Could not open \(url.absoluteString). Open the app or guide manually."
        }
    }

    private func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This location is no longer available or cannot be accessed. Scan again to refresh the results."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct AppleFeatureRow: View {
    let feature: AppleFeature
    let version: OperatingSystemVersion
    let openDestination: (String) -> Void
    let openGuide: (URL) -> Void
    @State private var expanded = false

    private var available: Bool { feature.isAvailable(on: version) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(feature.steps)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    Button(feature.destination.hasPrefix("application:") ? "Open Mail" : "Open Settings") {
                        openDestination(feature.destination)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!available)
                    Button("Apple guide") { openGuide(feature.guide) }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12))
            }
            .padding(.top, 10)
            .padding(.leading, 2)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(feature.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if !available {
                        Text("Requires macOS \(feature.minimumVersion.majorVersion).\(feature.minimumVersion.minorVersion)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(feature.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .accessibilityIdentifier("appleFeatures.feature.\(feature.id)")
    }
}

private struct AppleStorageRow: View {
    let item: AppleStorageItem
    let reveal: (URL) -> Void
    let openDestination: (String) -> Void

    private var sizeDescription: String {
        switch item.status {
        case .notPresent: return String(localized: "Not found")
        case .unavailable: return String(localized: "Unavailable")
        case .complete, .partial:
            guard let bytes = item.allocatedBytes else { return String(localized: "Unknown") }
            if bytes == 0 {
                return item.status == .partial ? String(localized: "Not fully measured") : String(localized: "0 bytes")
            }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return item.status == .partial ? String(format: String(localized: "At least %@"), size) : size
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(sizeDescription)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if item.status == .partial {
                Text("Partial measurement: \(item.skippedCount) skipped, \(item.inaccessibleCount) inaccessible.\(item.reachedLimit ? " Entry limit reached." : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(Tint.orange)
            } else if item.status == .unavailable {
                Text("This location could not be measured. Permissions or protected system storage may prevent access.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("Show in Finder") { reveal(item.url) }
                    .disabled(item.status == .notPresent || item.status == .unavailable)
                if item.kind == .screenSavers {
                    Button("Wallpaper settings") { openDestination("com.apple.Wallpaper-Settings.extension") }
                } else {
                    Button("Storage settings") { openDestination("com.apple.settings.Storage") }
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
        }
        .padding(16)
    }
}

private struct DeviceBackupRemovalReport: View {
    let result: DeviceBackupRemovalResult
    let dismiss: () -> Void

    var body: some View {
        CardSurface(padding: 16, elevation: .flat) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(result.removedPaths.count) backups moved to the Trash")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Dismiss report", action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Text("Moving backups to the Trash does not free disk space. Emptying the Trash is a separate action.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(Array(result.errors.enumerated()), id: \.offset) { _, error in
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !result.removedPaths.isEmpty {
                    DisclosureGroup("Moved paths") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.removedPaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}

private struct DeviceBackupConfirmation: View {
    let backups: [DeviceBackup]
    let canRemove: Bool
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(backups.count) backups to the Trash?")
                .font(.system(size: 19, weight: .semibold))
            Text("Removing your only backup prevents you from restoring that device from this Mac. Disconnect devices and stop any active backups before continuing.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(backups) { backup in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.url.path)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(ByteCountFormatter.string(fromByteCount: backup.allocatedSize, countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text("PureMac rechecks each selected backup before moving it. Emptying the Trash is a separate action.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !canRemove {
                Text("Wait for the current scan or cleanup to finish before moving backups.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRemove)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
