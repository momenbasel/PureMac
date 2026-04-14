import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel
    @AppStorage("PureMac.Appearance") private var appearance: AppAppearance = .system

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape.fill")
                }

            ScheduleSettingsTab()
                .environmentObject(vm)
                .tabItem {
                    Label("Schedule", systemImage: "clock.fill")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .frame(width: 520, height: 480)
        .preferredColorScheme(appearance.colorScheme)
        .focusable(false)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @AppStorage("PureMac.LaunchAtLogin") private var launchAtLogin = false
    @AppStorage("PureMac.ShowInDock") private var showInDock = true
    @AppStorage("PureMac.ShowMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("PureMac.Appearance") private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Appearance", systemImage: "paintbrush.fill")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show in Dock", isOn: $showInDock)
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            } header: {
                Label("App Behavior", systemImage: "switch.2")
            }

            Section {
                Text("PureMac will never delete system-critical files. Only caches, logs, temporary files, and user-selected items are removed.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Safety", systemImage: "shield.checkered")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Schedule Settings

struct ScheduleSettingsTab: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { vm.scheduler.config.isEnabled },
                    set: { vm.scheduler.toggleEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic Cleaning")
                            .font(.system(size: 13, weight: .medium))
                        Text("Automatically scan and clean your Mac on a schedule")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Picker("Scan Interval", selection: Binding(
                    get: { vm.scheduler.config.interval },
                    set: { vm.scheduler.updateSchedule(interval: $0) }
                )) {
                    ForEach(ScheduleInterval.allCases) { interval in
                        Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                    }
                }
                .disabled(!vm.scheduler.config.isEnabled)
            } header: {
                Label("Schedule", systemImage: "calendar.badge.clock")
            }

            Section {
                Toggle("Auto-clean after scan", isOn: $vm.scheduler.config.autoClean)
                    .disabled(!vm.scheduler.config.isEnabled)

                if vm.scheduler.config.autoClean {
                    Picker("Minimum junk size", selection: Binding(
                        get: { vm.scheduler.config.minimumCleanSize },
                        set: { vm.scheduler.config.minimumCleanSize = $0 }
                    )) {
                        Text("50 MB").tag(Int64(50 * 1024 * 1024))
                        Text("100 MB").tag(Int64(100 * 1024 * 1024))
                        Text("250 MB").tag(Int64(250 * 1024 * 1024))
                        Text("500 MB").tag(Int64(500 * 1024 * 1024))
                        Text("1 GB").tag(Int64(1024 * 1024 * 1024))
                    }
                }

                Toggle("Auto-purge purgeable space", isOn: $vm.scheduler.config.autoPurge)
                    .disabled(!vm.scheduler.config.isEnabled)

                Toggle("Show notification on completion", isOn: $vm.scheduler.config.notifyOnCompletion)
                    .disabled(!vm.scheduler.config.isEnabled)
            } header: {
                Label("Automation", systemImage: "bolt.fill")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last run")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(vm.scheduler.config.formattedLastRun)
                            .font(.system(size: 12, weight: .medium))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Next run")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(vm.scheduler.config.formattedNextRun)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            } header: {
                Label("Status", systemImage: "chart.bar.fill")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon
            Image("SidebarLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

            Spacer().frame(height: 16)

            Text("PureMac")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Spacer().frame(height: 4)

            Text("Version \(AppConstants.appVersion)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer().frame(height: 16)

            Text("A free, open-source Mac cleaning utility.\nKeep your Mac fast, clean, and optimized.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 20)

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/momenbasel/PureMac")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("GitHub Repository")
                            .font(.system(size: 12))
                    }
                }

                Text("MIT License")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(24)
    }
}
