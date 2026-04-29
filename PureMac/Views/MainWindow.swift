import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailContainer
        }
        .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 320)
        .frame(minWidth: 980, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                appearancePicker
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("Open System Settings") {
                FullDiskAccessManager.shared.openFullDiskAccessSettings()
                appState.cleanError = nil
            }
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section {
                navRow(section: .cleaning(.smartScan), label: "Dashboard",
                       icon: "sparkles", tint: Tint.blue,
                       badge: dashboardBadge)
            } header: { sectionLabel("Overview") }

            Section {
                navRow(section: .apps, label: "Installed Apps",
                       icon: "square.grid.2x2.fill", tint: Tint.purple,
                       badge: appState.installedApps.isEmpty ? nil : "\(appState.installedApps.count)")
                navRow(section: .orphans, label: "Orphaned Files",
                       icon: "doc.questionmark.fill", tint: Tint.pink,
                       badge: appState.orphanedFiles.isEmpty ? nil : "\(appState.orphanedFiles.count)")
            } header: { sectionLabel("Applications") }

            Section {
                ForEach(CleaningCategory.scannable) { category in
                    navRow(section: .cleaning(category),
                           label: category.rawValue,
                           icon: category.icon,
                           tint: category.color,
                           badge: sizeBadge(for: category))
                }
            } header: { sectionLabel("Cleanup") }
        }
        .listStyle(.sidebar)
        .navigationTitle("PureMac")
        .safeAreaInset(edge: .bottom) {
            healthFooter
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func navRow(section: AppSection, label: String, icon: String,
                        tint: Color, badge: String?) -> some View {
        HStack(spacing: 10) {
            IconTile(systemName: icon, tint: tint, size: 24)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 1)
        .tag(section)
    }

    private var dashboardBadge: String? {
        appState.totalJunkSize > 0
            ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
            : nil
    }

    private func sizeBadge(for category: CleaningCategory) -> String? {
        guard let size = appState.categoryResults[category]?.totalSize, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var healthFooter: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(appState.hasFullDiskAccess ? Tint.green : Tint.orange)
                .frame(width: 8, height: 8)
                .background(
                    Circle()
                        .fill((appState.hasFullDiskAccess ? Tint.green : Tint.orange).opacity(0.25))
                        .frame(width: 18, height: 18)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.hasFullDiskAccess ? "Ready to clean" : "Limited access")
                    .font(.system(size: 12, weight: .semibold))
                Text(appState.hasFullDiskAccess ? "Full Disk Access granted" : "Grant FDA in Settings")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Toolbar

    private var appearancePicker: some View {
        AppearancePill(selection: Binding(
            get: { theme.appearance },
            set: { theme.appearance = $0 }
        ))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            if !appState.hasFullDiskAccess && !appState.fdaBannerDismissed {
                fdaToast
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            detailView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .apps:
            AppListView()
        case .orphans:
            OrphanListView()
        case .cleaning(let category):
            if category == .smartScan {
                DashboardView()
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView("PureMac", systemImage: "sparkles",
                           description: "Select a category from the sidebar to get started.")
        }
    }

    // Card-shaped FDA toast that matches the dashboard surface aesthetic
    // rather than the flat orange bar.
    private var fdaToast: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access required")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                Text("macOS blocks PureMac from cleaning caches and uninstalling apps until you grant access.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Spacer()

            Button("Grant Access") {
                FullDiskAccessManager.shared.openFullDiskAccessSettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Tint.orange)

            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(colors: [Tint.orange, Color(red: 1.0, green: 0.42, blue: 0.0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .shadow(color: Tint.orange.opacity(0.35), radius: 12, y: 4)
    }
}
