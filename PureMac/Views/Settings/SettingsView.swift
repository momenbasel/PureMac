import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            CleaningSettingsView()
                .tabItem { Label("Cleaning", systemImage: "trash") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "clock") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
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

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch PureMac at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section("App Scanning") {
                Picker("Search sensitivity", selection: $sensitivity) {
                    ForEach(SearchSensitivity.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(level.rawValue)
                            Text(level.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Safety") {
                Toggle("Confirm before deleting files", isOn: $confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
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
            // Revert the toggle if operation failed
            launchAtLogin = !enabled
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
                Stepper("Minimum size: \(largeFileThresholdMB) MB", value: $largeFileThresholdMB, in: 10...1000, step: 10)
                Stepper("Files older than: \(oldFileMonths) months", value: $oldFileMonths, in: 1...60)
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
                            Text(interval.rawValue).tag(interval)
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
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
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
