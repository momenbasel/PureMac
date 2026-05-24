import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var permission = PermissionCoordinator.shared
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
            permission.refreshStatus()
        }
        .onChange(of: appState.cleanErrorIsFDAFixable) { isFDAFixable in
            // Auto-route FDA-fixable clean errors straight into the rich
            // sheet — skip the generic alert entirely so the user gets
            // 1-tap remediation instead of "Check the log for details".
            guard isFDAFixable else { return }
            let pending = appState.pendingPermissionRetryItems
            appState.cleanError = nil
            appState.cleanErrorIsFDAFixable = false
            appState.requestFullDiskAccessAndRetry(
                items: pending,
                context: .cleanup(failedCount: pending.count)
            )
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil && !appState.cleanErrorIsFDAFixable },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { permission.isRequesting },
            set: { if !$0 { permission.dismiss(callRetry: false) } }
        )) {
            PermissionSheet()
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
                           label: LocalizedStringKey(category.rawValue),
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

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func navRow(section: AppSection, label: LocalizedStringKey, icon: String,
                        tint: Color, badge: String?) -> some View {
        let isSelected = selectedSection == section
        return HStack(spacing: 10) {
            IconTile(systemName: icon, tint: tint, size: 24, glow: isSelected)
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            (isSelected ? tint : Color.primary).opacity(isSelected ? 0.15 : 0.06)
                        )
                    )
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
        let ok = appState.hasFullDiskAccess
        let tint = ok ? Tint.green : Tint.orange
        return HStack(spacing: 10) {
            PulsingDot(tint: tint, isPulsing: !ok)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(ok ? "Ready to clean" : "Limited access"))
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(ok ? "Full Disk Access granted" : "Grant FDA in Settings"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button {
                    permission.requestAccess(context: .general) {
                        appState.checkFullDiskAccess()
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [Tint.orange, Color(red: 1, green: 0.42, blue: 0.0)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        )
                        .shadow(color: Tint.orange.opacity(0.45), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help("Fix permission")
            }
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

    @ViewBuilder
    private var pulsingLockIcon: some View {
        pulsingLockIconView()
    }

    // Premium FDA toast — gradient backdrop, glow, primary action plus a
    // subtle dismiss. Visually distinct enough that users actually notice
    // and act on it without it screaming.
    private var fdaToast: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                pulsingLockIcon
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access required")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("1-tap setup. We'll auto-retry what failed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Spacer()

            Button {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            } label: {
                Label("Quick Setup", systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Tint.orange)
            .controlSize(.large)

            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Tint.orange, Color(red: 1.0, green: 0.42, blue: 0.0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
        )
        .shadow(color: Tint.orange.opacity(0.45), radius: 14, y: 6)
    }
}

@ViewBuilder
private func pulsingLockIconView() -> some View {
    let base = Image(systemName: "lock.shield.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
    if #available(macOS 14.0, *) {
        base.symbolEffect(.pulse.byLayer, options: .repeating)
    } else {
        base
    }
}

/// Small reusable status dot with optional pulse. Used in the sidebar health
/// footer and other "system status" surfaces.
private struct PulsingDot: View {
    let tint: Color
    var isPulsing: Bool = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .stroke(tint.opacity(pulse ? 0.0 : 0.6), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.6 : 0.8)
            } else {
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 16, height: 16)
            }
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 3)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard isPulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
