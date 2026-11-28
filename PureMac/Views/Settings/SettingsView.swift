import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// The dedicated macOS Settings window owns its permission sheet. The main
    /// window already presents the shared coordinator's sheet for every page.
    var standalone = false
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedTab = SettingsTab.general
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

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
            // The standard Settings window already carries the title; only the
            // sidebar page repeats it as a header.
            if !standalone {
                HStack(spacing: 14) {

                    Text("Settings")
                        .font(.title.weight(.semibold))
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
            }

            Picker("Settings", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(LocalizedStringKey(tab.rawValue), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .accessibilityIdentifier("settings.tabs")

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView(permissionPresentation: standalone ? .settingsWindow : .mainWindow)
                case .cleaning: CleaningSettingsView()
                case .schedule: ScheduleSettingsView(scheduler: appState.scheduler)
                case .about: AboutSettingsView()
                }
            }
            .id(selectedTab)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: selectedTab)
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
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @AppStorage("settings.general.searchSensitivity") private var sensitivity: SearchSensitivity = .enhanced
    @AppStorage("settings.general.animateInterface") private var animateInterface = true
    @AppStorage("settings.general.menuBarMonitor") private var menuBarMonitor = false
    @AppStorage(Haptics.soundEffectsKey) private var soundEffects = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    private var languageNeedsRelaunch: Bool { appState.settingsNeedLanguageRestart }
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

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
                Toggle("Animate interface transitions", isOn: $animateInterface)
                    .accessibilityLabel(Text("Animate interface transitions"))
                    .accessibilityIdentifier("settings.animateInterface")
            }

            Section("Full Disk Access") {
                HStack(spacing: 12) {
                    ToolSymbol(systemName: appState.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield",
                             tint: appState.hasFullDiskAccess ? Tint.green : Tint.orange, size: 32)
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
                        .buttonStyle(.borderedProminent)
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
                if loginStatus == .requiresApproval {
                    LabeledContent("Approval required") {
                        Button("Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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

        }
        .formStyle(.grouped)
        .onAppear { refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
        .animation(motionEnabled ? .easeInOut(duration: 0.22) : nil,
                   value: languageNeedsRelaunch)
    }

    private func refreshAccess() {
        loginStatus = SMAppService.mainApp.status
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
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: toggleLaunchAtLogin
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
        loginError = nil
        defer { loginStatus = SMAppService.mainApp.status }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            loginError = error.localizedDescription
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
    @ObservedObject var scheduler: SchedulerService
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var notificationError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable scheduled scanning", isOn: Binding(
                    get: { scheduler.config.isEnabled },
                    set: { scheduler.toggleEnabled($0) }
                ))
                .accessibilityIdentifier("schedule.enabled")

                if scheduler.config.isEnabled {
                    Picker("Scan interval", selection: Binding(
                        get: { scheduler.config.interval },
                        set: { scheduler.updateSchedule(interval: $0) }
                    )) {
                        ForEach(ScheduleInterval.allCases) { interval in
                            Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                        }
                    }
                    .accessibilityIdentifier("schedule.interval")

                    Toggle(isOn: $scheduler.config.autoClean) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto-clean after scan")
                            Text(String(format: String(localized: "Auto-clean can permanently remove files when eligible items reach %@. Trash stays for manual review."),
                                        ByteCountFormatter.string(fromByteCount: scheduler.config.minimumCleanSize, countStyle: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Notify on completion", isOn: $scheduler.config.notifyOnCompletion)
                    if scheduler.config.notifyOnCompletion {
                        notificationControls
                    }
                }
            } header: {
                Text("Automatic Scanning")
            } footer: {
                Text("Scheduled scans run while PureMac is open. An unfinished review waits for you.")
            }

            if scheduler.config.isEnabled || scheduler.config.lastRunDate != nil {
                Section {
                    if scheduler.config.isEnabled {
                        LabeledContent {
                            if scheduler.isRunning {
                                Label("In progress", systemImage: "magnifyingglass")
                                    .foregroundStyle(Tint.accent)
                            } else if scheduler.isDeferred {
                                Label("Waiting for the current operation or review", systemImage: "pause.circle")
                            } else if let next = scheduler.config.nextRunDate {
                                Text(next.formatted(date: .abbreviated, time: .shortened))
                                    .monospacedDigit()
                            }
                        } label: {
                            Label("Next run", systemImage: "calendar.badge.clock")
                        }
                        .accessibilityIdentifier("schedule.next")
                    }
                    LabeledContent {
                        if let last = scheduler.config.lastRunDate {
                            Text(last.formatted(date: .abbreviated, time: .shortened))
                                .monospacedDigit()
                        } else {
                            Text("Never")
                        }
                    } label: {
                        Label("Last completed scan", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(motionEnabled ? .easeInOut(duration: 0.22) : nil,
                   value: scheduler.config.isEnabled)
        .task(id: scheduler.config.isEnabled && scheduler.config.notifyOnCompletion) {
            await refreshNotificationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    @ViewBuilder
    private var notificationControls: some View {
        if notificationStatus == .notDetermined {
            Button("Allow notifications") {
                Task {
                    do {
                        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        notificationError = nil
                        await refreshNotificationStatus()
                    } catch {
                        notificationError = error.localizedDescription
                    }
                }
            }
        } else if notificationStatus == .denied {
            if let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                Link("Open Notification Settings", destination: settings)
            }
        }
        if let notificationError {
            Text(notificationError)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshNotificationStatus() async {
        guard scheduler.config.isEnabled && scheduler.config.notifyOnCompletion else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
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
