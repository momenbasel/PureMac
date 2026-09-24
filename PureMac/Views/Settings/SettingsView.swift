import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// The dedicated macOS Settings window owns its permission sheet. The main
    /// window already presents the shared coordinator's sheet for every page.
    var standalone = false
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedTab = SettingsTab.general
    @ObservedObject private var updater = UpdateService.shared

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case cleaning = "Cleaning"
        case schedule = "Schedule"
        case about = "Updates"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .cleaning: return "trash"
            case .schedule: return "clock"
            case .about: return "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(systemName: "gearshape.fill", tint: Tint.accent, size: 44, corner: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 26, weight: .bold))
                    Text("Make PureMac work your way.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: String(localized: "Version %@"), UpdateService.installedVersion))
                    Text(String(format: String(localized: "Build %@"), UpdateService.installedBuild))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(.horizontal, 4)

            if !settingsIssues.isEmpty {
                CardSurface(padding: 12, elevation: .flat, tint: Tint.orange) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Settings to review", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tint.orange)
                        ForEach(settingsIssues) { issue in
                            Button {
                                selectedTab = issue.opensUpdates ? .about : .general
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: issue.icon).frame(width: 18)
                                    Text(issue.title)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("settings.review.\(issue.rawValue)")
                        }
                    }
                }
            }

            Picker("Settings", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(LocalizedStringKey(tab.rawValue), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.tabs")

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView(permissionPresentation: standalone ? .settingsWindow : .mainWindow)
                case .cleaning: CleaningSettingsView()
                case .schedule: ScheduleSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(24)
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop())
        .tint(Tint.accent)
        .navigationTitle("Settings")
        .onAppear { showRequestedUpdates() }
        .onChange(of: appState.showUpdateSettings) { _ in showRequestedUpdates() }
        .sheet(isPresented: Binding(
            get: { standalone && permission.isRequesting && permission.presentation == .settingsWindow },
            set: { if !$0 && standalone && permission.presentation == .settingsWindow { permission.dismiss(callRetry: false) } }
        )) { PermissionSheet() }
    }

    private var settingsIssues: [SettingsAttention.Issue] {
        SettingsAttention.issues(hasFullDiskAccess: appState.hasFullDiskAccess,
                                 updateState: updater.state,
                                 needsRestart: appState.settingsNeedLanguageRestart,
                                 startupError: appState.settingsStartupError)
    }

    private func showRequestedUpdates() {
        if !standalone && appState.showUpdateSettings {
            selectedTab = .about
            appState.showUpdateSettings = false
        }
    }
}

// MARK: - General

enum SearchSensitivity: String, CaseIterable, Identifiable, Codable {
    case strict = "Strict"
    case enhanced = "Enhanced"
    case deep = "Deep"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .strict: return "Exact bundle ID and name matches only. Safest option."
        case .enhanced: return "Includes partial name matching and bundle ID components."
        case .deep: return "Includes company name, entitlements, and team identifier matching."
        }
    }
}

struct GeneralSettingsView: View {
    var permissionPresentation: PermissionCoordinator.Presentation = .mainWindow
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var permission = PermissionCoordinator.shared
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.general.searchSensitivity") private var sensitivity: SearchSensitivity = .enhanced
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage("settings.general.menuBarMonitor") private var menuBarMonitor = false
    @AppStorage(Haptics.soundEffectsKey) private var soundEffects = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    private var languageNeedsRelaunch: Bool { appState.settingsNeedLanguageRestart }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $theme.appearance) {
                    ForEach(AppearanceMode.allCases) { appearance in
                        Label(LocalizedStringKey(appearance.label), systemImage: appearance.icon)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Full Disk Access") {
                HStack(spacing: 12) {
                    IconTile(systemName: appState.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield",
                             tint: appState.hasFullDiskAccess ? Tint.green : Tint.orange, size: 32, corner: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(appState.hasFullDiskAccess ? "Full access" : "Limited access"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(LocalizedStringKey(appState.hasFullDiskAccess ? "Ready for protected locations" : "Some locations are unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check access") { refreshAccess() }
                    if !appState.hasFullDiskAccess {
                        Button("Set up") {
                            permission.requestAccess(context: .general, presentation: permissionPresentation) { refreshAccess() }
                        }
                        .tint(Tint.accent)
                    }
                }
            }

            Section("Language") {
                Picker("Language", selection: appLanguageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }

                if languageNeedsRelaunch {
                    Text("Restart PureMac to apply the selected language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Button("Relaunch Now") {
                        relaunchApp()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("Startup") {
                Toggle("Launch PureMac at login", isOn: launchAtLoginBinding)
                if let error = appState.settingsStartupError {
                    Text(error).font(.caption).foregroundStyle(Tint.orange)
                }
            }

            Section("App Scanning") {
                Picker("Search sensitivity", selection: $sensitivity) {
                    ForEach(SearchSensitivity.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(LocalizedStringKey(level.rawValue))
                            Text(LocalizedStringKey(level.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("System Monitor") {
                Toggle("Show system monitor in menu bar", isOn: menuBarMonitorBinding)
                Text("Live CPU, memory, and disk meters in the menu bar. PureMac keeps running in the background while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                Toggle("Play sound effects", isOn: $soundEffects)
            }

            Section("Safety") {
                Toggle("Confirm before deleting files", isOn: $confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: languageNeedsRelaunch)
    }

    private func refreshAccess() {
        appState.checkFullDiskAccess()
        permission.refreshStatus()
    }

    private var menuBarMonitorBinding: Binding<Bool> {
        Binding(
            get: { menuBarMonitor },
            set: { newValue in
                menuBarMonitor = newValue
                // Tell AppDelegate to add/remove the status item without relaunch.
                NotificationCenter.default.post(name: .pureMacMenuBarMonitorChanged, object: nil)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                toggleLaunchAtLogin(newValue)
            }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { newValue in
                appLanguageRaw = newValue.rawValue
                applyLanguage(newValue)
            }
        )
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appState.settingsStartupError = nil
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            launchAtLogin = !enabled
            appState.settingsStartupError = error.localizedDescription
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        AppLanguagePreferences.apply(language)
        appState.settingsNeedLanguageRestart = language != appState.languageAtLaunch
    }

    private func relaunchApp() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Logger.shared.log("Failed to relaunch PureMac: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Cleaning

struct CleaningSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.cleaning.skipHiddenFiles") private var skipHiddenFiles = true
    @AppStorage("settings.cleaning.largeFileThreshold") private var largeFileThresholdMB: Int = 100
    @AppStorage("settings.cleaning.oldFileMonths") private var oldFileMonths: Int = 12

    private static let excludedFoldersKey = "settings.cleaning.largeFileExcludedFolders"
    @State private var excludedFolders: [String] = []

    var body: some View {
        Form {
            Section("File Discovery") {
                Toggle("Skip hidden files during scan", isOn: $skipHiddenFiles)
            }

            Section("Large Files") {
                Stepper(
                    String(format: String(localized: "Minimum size: %lld MB"), Int64(largeFileThresholdMB)),
                    value: $largeFileThresholdMB,
                    in: 10...1000,
                    step: 10
                )
                Stepper(
                    String(format: String(localized: "Files older than: %lld months"), Int64(oldFileMonths)),
                    value: $oldFileMonths,
                    in: 1...60
                )
            }

            Section("Excluded Folders") {
                if excludedFolders.isEmpty {
                    Text("Files inside these folders are skipped from the Large & Old Files scan (Downloads, Documents, Desktop).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder)
                            Spacer()
                            Button {
                                removeExcludedFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove from exclusions"))
                        }
                    }
                }
                Button("Add Folder…") { addExcludedFolder() }
            }

            Section("Cleanup Exclusions") {
                Text("Excluded paths and folders containing them stay out of manual and scheduled cleanup. Right-click a cleanup result to exclude it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.excludedCleanupPaths.isEmpty {
                    Text("No excluded paths").foregroundStyle(.secondary)
                }
                ForEach(appState.excludedCleanupPaths, id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button("Remove") { appState.removeCleanupExclusion(path) }
                            .disabled(appState.scanState.isActive)
                    }
                }
            }

            Section("Orphan Finder") {
                HStack {
                    // Read the live count directly (it's a UserDefaults-backed
                    // computed property on AppState) so it stays correct when
                    // orphans are ignored from the Orphans view while this tab
                    // is open. AppState fires objectWillChange on both ignore
                    // (via @Published orphanedFiles) and clear, re-rendering this.
                    Text(String(format: String(localized: "Ignored orphans: %lld"), Int64(appState.ignoredOrphanCount)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Ignored") {
                        appState.clearIgnoredOrphans()
                    }
                    .disabled(appState.ignoredOrphanCount == 0)
                }
                Text("Ignored files won't appear in future orphan scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            excludedFolders = UserDefaults.standard.stringArray(forKey: Self.excludedFoldersKey) ?? []
        }
    }

    private func persistExcludedFolders() {
        UserDefaults.standard.set(excludedFolders, forKey: Self.excludedFoldersKey)
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder…")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !excludedFolders.contains(url.path) {
            excludedFolders.append(url.path)
        }
        persistExcludedFolders()
    }

    private func removeExcludedFolder(_ folder: String) {
        excludedFolders.removeAll { $0 == folder }
        persistExcludedFolders()
    }
}

// MARK: - Schedule

struct ScheduleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Automatic Scanning") {
                Toggle("Enable scheduled scanning", isOn: $appState.scheduler.config.isEnabled)

                if appState.scheduler.config.isEnabled {
                    Group {
                        Picker("Scan interval", selection: $appState.scheduler.config.interval) {
                            ForEach(ScheduleInterval.allCases) { interval in
                                Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                            }
                        }

                        Toggle("Auto-clean after scan", isOn: $appState.scheduler.config.autoClean)
                        Toggle("Notify on completion", isOn: $appState.scheduler.config.notifyOnCompletion)

                        HStack {
                            Text("Last run")
                            Spacer()
                            Text(appState.scheduler.config.formattedLastRun)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: appState.scheduler.config.isEnabled)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PureMac")
                            .font(.title2.bold())
                        Text(
                            String(
                                format: String(localized: "Version %@"),
                                UpdateService.installedVersion
                            )
                        )
                            .foregroundStyle(.secondary)
                        Text("Free, open-source macOS app manager.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section("Updates") {
                AppUpdateSettingsView()
            }

            Section {
                Link("GitHub Repository", destination: URL(string: "https://github.com/momenbasel/PureMac")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/momenbasel/PureMac/issues")!)
            }

            Section {
                Text("MIT License")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
