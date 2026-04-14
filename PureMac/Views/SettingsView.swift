import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        TabView {
            ScheduleSettingsTab()
                .environmentObject(vm)
                .tabItem {
                    Label("Schedule", systemImage: "clock.fill")
                }

            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape.fill")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - Schedule Settings

struct ScheduleSettingsTab: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Enable toggle
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { vm.scheduler.config.isEnabled },
                    set: { vm.scheduler.toggleEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic Cleaning")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Automatically scan and clean your Mac on a schedule")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Divider()

            // Interval picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan Interval")
                    .font(.system(size: 13, weight: .semibold))

                Picker("", selection: Binding(
                    get: { vm.scheduler.config.interval },
                    set: { vm.scheduler.updateSchedule(interval: $0) }
                )) {
                    ForEach(ScheduleInterval.allCases) { interval in
                        Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .disabled(!vm.scheduler.config.isEnabled)
            }

            Divider()

            // Auto-clean options
            VStack(alignment: .leading, spacing: 12) {
                Text("Automation")
                    .font(.system(size: 13, weight: .semibold))

                Toggle("Auto-clean after scan", isOn: $vm.scheduler.config.autoClean)
                    .toggleStyle(.switch)
                    .disabled(!vm.scheduler.config.isEnabled)

                if vm.scheduler.config.autoClean {
                    HStack {
                        Text("Minimum junk size to trigger clean:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Picker("", selection: Binding(
                            get: { vm.scheduler.config.minimumCleanSize },
                            set: { vm.scheduler.config.minimumCleanSize = $0 }
                        )) {
                            Text("50 MB").tag(Int64(50 * 1024 * 1024))
                            Text("100 MB").tag(Int64(100 * 1024 * 1024))
                            Text("250 MB").tag(Int64(250 * 1024 * 1024))
                            Text("500 MB").tag(Int64(500 * 1024 * 1024))
                            Text("1 GB").tag(Int64(1024 * 1024 * 1024))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    .padding(.leading, 20)
                }

                Toggle("Auto-purge purgeable space", isOn: $vm.scheduler.config.autoPurge)
                    .toggleStyle(.switch)
                    .disabled(!vm.scheduler.config.isEnabled)

                Toggle("Show notification on completion", isOn: $vm.scheduler.config.notifyOnCompletion)
                    .toggleStyle(.switch)
                    .disabled(!vm.scheduler.config.isEnabled)
            }

            Divider()

            // Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last run")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(vm.scheduler.config.formattedLastRun)
                            .font(.system(size: 12, weight: .medium))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next run")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(vm.scheduler.config.formattedNextRun)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }

            Spacer()
        }
        .padding(24)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @AppStorage("PureMac.LaunchAtLogin") private var launchAtLogin = false
    @AppStorage("PureMac.ShowInDock") private var showInDock = true
    @AppStorage("PureMac.ShowMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("App Behavior")
                    .font(.system(size: 13, weight: .semibold))

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)

                Toggle("Show in Dock", isOn: $showInDock)
                    .toggleStyle(.switch)

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Safety")
                    .font(.system(size: 13, weight: .semibold))

                Text("PureMac will never delete system-critical files. Only caches, logs, temporary files, and user-selected items are removed.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(24)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "6366f1"), Color(hex: "a855f7")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("PureMac")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Version \(AppConstants.appVersion)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("A free, open-source Mac cleaning utility.\nKeep your Mac fast, clean, and optimized.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Link("GitHub Repository", destination: URL(string: "https://github.com/momenbasel/PureMac")!)
                .font(.system(size: 12))

            Text("MIT License")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
