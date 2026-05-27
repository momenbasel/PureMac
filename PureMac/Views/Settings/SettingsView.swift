import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            CleaningSettingsView()
                .tabItem { Label("Cleaning", systemImage: "trash") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "clock") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 430)
    }
}

// MARK: - Updates

enum UpdateInterval: String, CaseIterable, Identifiable, Codable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .daily: return 60 * 60 * 24
        case .weekly: return 60 * 60 * 24 * 7
        case .monthly: return 60 * 60 * 24 * 30
        }
    }
}

struct UpdatesSettingsView: View {
    @State private var automaticallyChecks: Bool = true
    @State private var interval: UpdateInterval = .weekly

    init() {
        if let updater = UpdateService.shared.updater {
            _automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
            let seconds = updater.updateCheckInterval
            if let matched = UpdateInterval.allCases.first(where: { $0.timeInterval == seconds }) {
                _interval = State(initialValue: matched)
            } else {
                _interval = State(initialValue: .weekly)
            }
        } else {
            let defaults = UserDefaults.standard
            let enabled = defaults.object(forKey: "settings.updates.checkAutomatically") as? Bool ?? true
            let raw = defaults.string(forKey: "settings.updates.checkInterval") ?? UpdateInterval.weekly.rawValue
            _automaticallyChecks = State(initialValue: enabled)
            _interval = State(initialValue: UpdateInterval(rawValue: raw) ?? .weekly)
        }
    }

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { newValue in
                        UpdateService.shared.setAutomaticallyChecks(newValue)
                    }

                Picker("Check interval", selection: Binding(
                    get: { interval },
                    set: { newValue in
                        interval = newValue
                        UpdateService.shared.setUpdateInterval(newValue.timeInterval)
                    }
                )) {
                    ForEach(UpdateInterval.allCases) { value in
                        Text(LocalizedStringKey(value.rawValue)).tag(value)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!automaticallyChecks)

                HStack {
                    Spacer()
                    Button("Check Now") {
                        UpdateService.shared.checkForUpdates()
                    }
                    .keyboardShortcut("u", modifiers: [.command])
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync UI from updater in case external changes occurred
            if let updater = UpdateService.shared.updater {
                automaticallyChecks = updater.automaticallyChecksForUpdates
                let seconds = updater.updateCheckInterval
                if let matched = UpdateInterval.allCases.first(where: { $0.timeInterval == seconds }) {
                    interval = matched
                }
            }
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
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.general.searchSensitivity") private var sensitivity: SearchSensitivity = .enhanced
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    @State private var languageNeedsRelaunch = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch PureMac at login", isOn: launchAtLoginBinding)
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

                    Button("Relaunch Now") {
                        relaunchApp()
                    }
                }
            }

            Section("Safety") {
                Toggle("Confirm before deleting files", isOn: $confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
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
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            launchAtLogin = !enabled
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        AppLanguagePreferences.apply(language)
        languageNeedsRelaunch = true
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
    @AppStorage("settings.cleaning.skipHiddenFiles") private var skipHiddenFiles = true
    @AppStorage("settings.cleaning.largeFileThreshold") private var largeFileThresholdMB: Int = 100
    @AppStorage("settings.cleaning.oldFileMonths") private var oldFileMonths: Int = 12

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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Schedule

struct ScheduleSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Automatic Scanning") {
                Toggle("Enable scheduled scanning", isOn: $appState.scheduler.config.isEnabled)

                if appState.scheduler.config.isEnabled {
                    Picker("Scan interval", selection: $appState.scheduler.config.interval) {
                        ForEach(ScheduleInterval.allCases) { interval in
                            Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                        }
                    }

                    Toggle("Auto-clean after scan", isOn: $appState.scheduler.config.autoClean)
                    Toggle("Auto-purge purgeable space", isOn: $appState.scheduler.config.autoPurge)
                    Toggle("Notify on completion", isOn: $appState.scheduler.config.notifyOnCompletion)

                    HStack {
                        Text("Last run")
                        Spacer()
                        Text(appState.scheduler.config.formattedLastRun)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                            )
                        )
                            .foregroundStyle(.secondary)
                        Text("Free, open-source macOS app manager.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
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
