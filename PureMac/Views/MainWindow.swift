import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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
        .onChange(of: appState.pendingExternalApp) { app in
            // A right-clicked app arrived via Finder Services — surface the
            // Installed Apps view so its related-files scan is visible.
            guard app != nil else { return }
            selectedSection = .apps
            appState.pendingExternalApp = nil
        }
        .onAppear {
            // Covers a request that landed before MainWindow mounted (cold
            // launch, or while onboarding was still showing) — onChange alone
            // fires only on subsequent changes and would miss it.
            if appState.pendingExternalApp != nil {
                selectedSection = .apps
                appState.pendingExternalApp = nil
            }
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
        SidebarNavRow(
            label: label, icon: icon, tint: tint, badge: badge,
            isSelected: selectedSection == section
        )
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
                    // Explicit solid color — same vibrancy-collapse guard as the
                    // sidebar rows (#117); this title also inherited the default.
                    .foregroundStyle(colorScheme == .dark
                        ? Color.white.opacity(0.92)
                        : Color.black.opacity(0.85))
                Text(LocalizedStringKey(ok ? "Full Disk Access granted" : "Grant FDA in Settings"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Fix") {
                    permission.requestAccess(context: .general) {
                        appState.checkFullDiskAccess()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.orange)
                .controlSize(.small)
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
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
            detailView
                .id(selectedSection)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity
                        )
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selectedSection)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: appState.fdaBannerDismissed)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: appState.hasFullDiskAccess)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop())
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

    // Quiet FDA bar — single tinted surface, no gradient or glow.
    private var fdaToast: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "lock.shield.fill", tint: Tint.orange, size: 32, corner: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("Full Disk Access required")
                    .font(.system(size: 13, weight: .semibold))
                Text("1-tap setup. We'll auto-retry what failed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Set up") {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tint.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Tint.orange.opacity(0.22), lineWidth: 0.5)
        )
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

/// Sidebar row with a springy hover highlight. Extracted to a struct so each
/// row owns its hover state; the selected row's IconTile glows via the shared
/// glow treatment in AppTheme.
private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let badge: String?
    let isSelected: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: icon, tint: tint, size: 24, glow: isSelected)
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                // Force an explicit, solid foreground instead of inheriting the
                // sidebar list's default. On some configs (custom accent /
                // reduced transparency, seen on M1 Max — issue #117) the
                // inherited emphasized/vibrant label style resolves transparent
                // and the row text disappears while explicitly-colored text
                // (headers, badges) stays visible. A colorScheme-driven solid
                // color sidesteps that vibrancy path entirely.
                .foregroundStyle(labelColor)
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
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 2)
        // Leading anchor keeps the row from clipping against the sidebar edge.
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1, anchor: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering && !isSelected ? 0.05 : 0))
                .padding(.horizontal, -6)
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Solid, opaque label color that adapts to light/dark without routing
    /// through the sidebar's vibrant primary style (see #117).
    private var labelColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
    }
}

/// Small reusable status dot with optional pulse. Used in the sidebar health
/// footer and other "system status" surfaces.
private struct PulsingDot: View {
    let tint: Color
    var isPulsing: Bool = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isPulsing && !reduceMotion {
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
        .onAppear { syncPulse() }
        // The FDA status can flip while the window stays open — onAppear
        // alone latches the first value and never starts/stops the loop.
        .onChange(of: isPulsing) { _ in syncPulse() }
    }

    private func syncPulse() {
        guard isPulsing, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
