import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var advancedToolsExpanded = false
    @FocusState private var focusedSection: AppSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let cleanupCategories: [CleaningCategory] = [
        .systemJunk,
        .userCache,
        .mailAttachments,
        .trashBins,
        .largeFiles,
    ]

    // Filtered against `scannable` so a category withdrawn there (see
    // CleaningCategory.appModifying) cannot linger here as a dead sidebar row.
    private static let advancedCategories: [CleaningCategory] = [
        .aiApps,
        .xcodeJunk,
        .brewCache,
        .nodeCache,
        .dockerCache,
    ].filter(CleaningCategory.scannable.contains)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 300)
        } detail: {
            detailContainer
        }
        .frame(minWidth: 980, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
            permission.refreshStatus()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            // A right-clicked app arrived via Finder Services — surface the
            // Installed Apps view so its related-files scan is visible.
            guard app != nil else { return }
            selectSection(.apps)
            appState.pendingExternalApp = nil
        }
        .onAppear {
            // Covers a request that landed before MainWindow mounted (cold
            // launch, or while onboarding was still showing) — onChange alone
            // fires only on subsequent changes and would miss it.
            if appState.pendingExternalApp != nil {
                selectSection(.apps)
                appState.pendingExternalApp = nil
            } else if let selectedSection {
                focusedSection = selectedSection
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
        List {
            Section {
                navRow(section: .cleaning(.smartScan), label: "Smart Care",
                       icon: "sparkles",
                       tint: SidebarPalette.smartCarePrimary,
                       secondaryTint: SidebarPalette.smartCareSecondary,
                       badge: dashboardBadge,
                       isFeatured: true)
            } header: { sectionLabel("Overview") }

            Section {
                ForEach(Self.cleanupCategories) { category in
                    navRow(section: .cleaning(category),
                           label: LocalizedStringKey(category.rawValue),
                           icon: category.icon,
                           tint: category.color,
                           secondaryTint: category.color,
                           badge: sizeBadge(for: category))
                }
            } header: { sectionLabel("Cleanup") }

            Section {
                navRow(section: .apps, label: "Installed Apps",
                       icon: "square.grid.2x2.fill",
                       tint: SidebarPalette.applicationsPrimary,
                       secondaryTint: SidebarPalette.applicationsSecondary,
                       badge: appState.installedApps.isEmpty ? nil : "\(appState.installedApps.count)")
                navRow(section: .orphans, label: "Orphaned Files",
                       icon: "doc.questionmark.fill",
                       tint: Tint.orange,
                       secondaryTint: Tint.orange,
                       badge: appState.orphanedFiles.isEmpty ? nil : "\(appState.orphanedFiles.count)")
            } header: { sectionLabel("Applications") }

            Section {
                DisclosureGroup(isExpanded: $advancedToolsExpanded) {
                    ForEach(Self.advancedCategories) { category in
                        navRow(section: .cleaning(category),
                               label: LocalizedStringKey(category.rawValue),
                               icon: category.icon,
                               tint: category.color,
                               secondaryTint: category.color,
                               badge: sizeBadge(for: category))
                    }
                } label: {
                    HStack(spacing: 9) {
                        IconTile(
                            systemName: "wrench.and.screwdriver.fill",
                            tint: SidebarPalette.advanced,
                            size: 24,
                            corner: 7
                        )
                        Text("Advanced Tools")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(sidebarLabelColor)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .tint(.secondary)
                .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 36)
        .scrollContentBackground(.hidden)
        .background(sidebarBackdrop)
        .navigationTitle("PureMac")
        .onMoveCommand(perform: moveSelection)
        .onChange(of: selectedSection) { section in
            guard case let .cleaning(category)? = section,
                  Self.advancedCategories.contains(category) else { return }
            withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
                advancedToolsExpanded = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
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
                        tint: Color, secondaryTint: Color, badge: String?,
                        isFeatured: Bool = false) -> some View {
        Button {
            selectSection(section)
        } label: {
            SidebarNavRow(
                label: label,
                icon: icon,
                tint: tint,
                secondaryTint: secondaryTint,
                badge: badge,
                isSelected: selectedSection == section,
                isFeatured: isFeatured
            )
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: section)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var visibleSections: [AppSection] {
        var sections: [AppSection] = [.cleaning(.smartScan)]
        sections.append(contentsOf: Self.cleanupCategories.map(AppSection.cleaning))
        sections.append(contentsOf: [.apps, .orphans])
        if advancedToolsExpanded {
            sections.append(contentsOf: Self.advancedCategories.map(AppSection.cleaning))
        }
        return sections
    }

    private func selectSection(_ section: AppSection) {
        selectedSection = section
        focusedSection = section
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = visibleSections
        guard !sections.isEmpty else { return }

        let current = focusedSection ?? selectedSection
        let currentIndex = current.flatMap(sections.firstIndex(of:))
        let targetIndex: Int

        switch direction {
        case .up:
            targetIndex = max(0, (currentIndex ?? sections.count) - 1)
        case .down:
            targetIndex = min(sections.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }

        selectSection(sections[targetIndex])
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

    private var sidebarBackdrop: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RadialGradient(
                colors: [
                    SidebarPalette.smartCarePrimary.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    SidebarPalette.smartCareSecondary.opacity(colorScheme == .dark ? 0.06 : 0.025),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.018 : 0.20),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.018),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var sidebarFooter: some View {
        VStack(spacing: 7) {
            healthFooter
            appearanceMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.42))
                .frame(height: 0.5)
        }
    }

    private var healthFooter: some View {
        let ok = appState.hasFullDiskAccess
        let tint = ok ? Tint.green : Tint.orange
        return HStack(spacing: 8) {
            PulsingDot(tint: tint, isPulsing: !ok)
                .scaleEffect(0.78)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(ok ? "Ready to clean" : "Limited access"))
                    .font(.system(size: 11, weight: .semibold))
                    // Explicit solid color — same vibrancy-collapse guard as the
                    // sidebar rows (#117); this title also inherited the default.
                    .foregroundStyle(sidebarLabelColor)
                Text(LocalizedStringKey(ok ? "Full Disk Access granted" : "Grant FDA in Settings"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !ok {
                Button("Fix") {
                    permission.requestAccess(context: .general) {
                        appState.checkFullDiskAccess()
                    }
                }
                .buttonStyle(.bordered)
                .tint(Tint.orange)
                .controlSize(.small)
                .help("Fix permission")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.44))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.62),
                    lineWidth: 0.5
                )
        )
    }

    private var appearanceMenu: some View {
        Menu {
            ForEach(AppearanceMode.allCases) { appearance in
                Button {
                    theme.appearance = appearance
                } label: {
                    Label(LocalizedStringKey(appearance.label), systemImage: appearance.icon)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: theme.appearance.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text("Appearance")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(sidebarLabelColor)

                Spacer(minLength: 6)

                Text(LocalizedStringKey(theme.appearance.label))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 26)
            .padding(.horizontal, 9)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .help("Change appearance")
        .accessibilityLabel("Appearance")
        .accessibilityValue(Text(LocalizedStringKey(theme.appearance.label)))
    }

    private var sidebarLabelColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
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
                DashboardView { selectSection($0) }
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

/// Premium navigation row with explicit selection, independent of List's
/// system-blue selection rendering.
private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let secondaryTint: Color
    let badge: String?
    let isSelected: Bool
    let isFeatured: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            IconTile(
                systemName: icon,
                tint: tint,
                size: 24,
                corner: 7,
                glow: isFeatured && isSelected,
                vivid: isFeatured
            )
                .shadow(
                    color: isFeatured ? tint.opacity(isSelected ? 0.52 : 0.28) : .clear,
                    radius: isFeatured ? (isSelected ? 9 : 5) : 0
                )
            Text(label)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
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
                    .font(.system(size: 9.75, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isFeatured && isSelected ? tint : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(isSelected ? 0.075 : 0.045))
                    )
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint, secondaryTint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.5, height: 20)
                    .padding(.leading, 3)
                    .shadow(
                        color: isFeatured ? tint.opacity(0.55) : .clear,
                        radius: isFeatured ? 5 : 0
                    )
            }
        }
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

        if isSelected {
            shape
                .fill(.thinMaterial)
                .overlay {
                    shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.24))
                }
                .overlay {
                    shape.strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.13 : 0.72),
                        lineWidth: 0.55
                    )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08),
                    radius: 5,
                    y: 2
                )
        } else {
            shape.fill(
                hovering
                    ? Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.032)
                    : Color.clear
            )
        }
    }

    /// Solid, opaque label color that adapts to light/dark without routing
    /// through the sidebar's vibrant primary style (see #117).
    private var labelColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
    }
}

private enum SidebarPalette {
    static let smartCarePrimary = Tint.purple
    static let smartCareSecondary = Tint.blue
    static let cleanupPrimary = Tint.blue
    static let cleanupSecondary = Tint.cyan
    static let applicationsPrimary = Tint.purple
    static let applicationsSecondary = Tint.pink
    static let advanced = Tint.orange
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
