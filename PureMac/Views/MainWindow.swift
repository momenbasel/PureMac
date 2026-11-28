import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var dashboardFilters = DashboardResultsFilters()
    @StateObject private var spaceExplorer = SpaceExplorerViewModel()
    @StateObject private var duplicateFinder = DuplicateFinderViewModel()
    @StateObject private var similarPhotos = SimilarPhotosViewModel()
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var navigationHistory: [AppSection] = []
    @State private var showsToolSwitcher = false
    @State private var toolDestination: AppSection?
    @State private var returnFocus: ToolReturnFocus?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var cleanupExpanded = false
    @State private var advancedToolsExpanded = false
    @State private var careExpanded = true
    @State private var applicationsExpanded = true
    @State private var toolsExpanded = true
    @FocusState private var focusedSection: AppSection?
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

    private static let cleanupCategories: [CleaningCategory] = [
        .systemJunk,
        .userCache,
        .mailAttachments,
        .trashBins,
        .largeFiles
    ]

    private static let advancedCategories: [CleaningCategory] = [
        .aiApps,
        .xcodeJunk,
        .brewCache,
        .nodeCache,
        .devToolCaches,
        .dockerCache,
        .rustTargets,
        .nodeModules
    ].filter(CleaningCategory.scannable.contains)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 212, ideal: 228, max: 288)
        } detail: {
            detailContainer
        }
        .frame(minWidth: 960, minHeight: 640)
        .appRemovalReviewPresentation()
        .sheet(isPresented: $showsToolSwitcher, onDismiss: finishToolSwitch) {
            ToolSwitcher(sections: sections(includingCollapsed: true), current: selectedSection) { section in
                toolDestination = section
                showsToolSwitcher = false
            } cancel: {
                showsToolSwitcher = false
            }
        }
        .onDisappear {
            spaceExplorer.cancel()
            duplicateFinder.cancelScan()
            duplicateFinder.leaveReview()
            similarPhotos.cancel()
        }
        .onChange(of: selectedSection) { section in
            if section != .duplicates { duplicateFinder.leaveReview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
            permission.refreshStatus()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            guard app != nil else { return }
            selectSection(.apps)
            appState.pendingExternalApp = nil
        }
        .onChange(of: appState.showUpdateSettings) { showUpdates in
            if showUpdates { selectSection(.settings) }
        }
        .onAppear {
            if appState.showUpdateSettings {
                selectSection(.settings)
            } else if appState.pendingExternalApp != nil {
                selectSection(.apps)
                appState.pendingExternalApp = nil
            } else if let selectedSection {
                focusedSection = selectedSection
            }
        }
        .onChange(of: appState.cleanErrorIsFDAFixable) { isFDAFixable in
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
            get: { permission.isRequesting && permission.presentation == .mainWindow },
            set: { if !$0 && permission.presentation == .mainWindow { permission.dismiss(callRetry: false) } }
        )) {
            PermissionSheet()
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { selectedSection },
            set: { section in
                if let section, section != selectedSection { selectSection(section) }
            }
        )) {
            Section {
                if careExpanded {
                    navRow(.cleaning(.smartScan), badge: dashboardBadge)
                    navRow(.protection)
                    navRow(.performance)
                    navRow(.appleFeatures)
                }
            } header: {
                collapsibleSectionHeader("Care", isExpanded: $careExpanded)
            }
            .collapsible(false)

            Section {
                if applicationsExpanded {
                    navRow(.apps, badge: appState.installedApps.isEmpty ? nil : appState.installedApps.count.formatted())
                    navRow(.appUpdates)
                    navRow(.orphans, badge: appState.orphanedFiles.isEmpty ? nil : appState.orphanedFiles.count.formatted())
                }
            } header: {
                collapsibleSectionHeader("Applications", isExpanded: $applicationsExpanded)
            }
            .collapsible(false)

            Section {
                if toolsExpanded {
                    navRow(.spaceExplorer, badge: spaceExplorer.isScanning ? String(localized: "Scanning") : nil)
                    navRow(.duplicates, badge: duplicateFinder.state == .scanning ? String(localized: "Scanning") : nil)
                    navRow(.similarPhotos, badge: similarPhotos.isScanning ? String(localized: "Scanning") : nil)
                    cleanupGroup("Cleanup", symbol: "trash", categories: Self.cleanupCategories, expanded: $cleanupExpanded)
                    cleanupGroup("Developer Cleanup", symbol: "wrench.and.screwdriver", categories: Self.advancedCategories, expanded: $advancedToolsExpanded)
                }
            } header: {
                collapsibleSectionHeader("Tools", isExpanded: $toolsExpanded)
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .navigationTitle("PureMac")
        .onMoveCommand(perform: moveSelection)
        .onChange(of: selectedSection) { section in
            guard let section else { return }
            withAnimation(motionEnabled ? MotionTokens.gentle : nil) {
                switch section {
                case .cleaning(.smartScan), .protection, .performance, .appleFeatures:
                    careExpanded = true
                case .apps, .appUpdates, .orphans:
                    applicationsExpanded = true
                case .spaceExplorer, .duplicates, .similarPhotos:
                    toolsExpanded = true
                case .cleaning(let category):
                    toolsExpanded = true
                    if Self.cleanupCategories.contains(category) {
                        cleanupExpanded = true
                    }
                    if Self.advancedCategories.contains(category) {
                        advancedToolsExpanded = true
                    }
                case .settings:
                    break
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private func cleanupGroup(
        _ title: LocalizedStringKey, symbol: String, categories: [CleaningCategory], expanded: Binding<Bool>
    ) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(categories) { category in
                navRow(.cleaning(category), badge: sizeBadge(for: category))
            }
        } label: {
            Label(title, systemImage: symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { expanded.wrappedValue.toggle() }
        }
    }

    private func collapsibleSectionHeader(
        _ title: LocalizedStringKey, isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(motionEnabled ? .easeOut(duration: 0.16) : nil) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.forward")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(nsColor: .labelColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(LocalizedStringKey(isExpanded.wrappedValue ? "Expanded" : "Collapsed")))
        .accessibilityAddTraits(.isHeader)
    }

    private func navRow(_ section: AppSection, badge: String? = nil) -> some View {
        Button {
            selectSection(section)
        } label: {
            HStack(spacing: 8) {
                Label(LocalizedStringKey(section.tool.name), systemImage: section.tool.symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let badge {
                    Text(verbatim: badge)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: section)
        .accessibilityLabel(Text(LocalizedStringKey(section.tool.name)))
        .accessibilityValue(Text(verbatim: badge ?? ""))
        .accessibilityIdentifier("sidebar.\(section.tool.id)")
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
        .tag(section)
    }

    private func sections(includingCollapsed: Bool) -> [AppSection] {
        var sections: [AppSection] = []
        if includingCollapsed || careExpanded {
            sections.append(contentsOf: [
                .cleaning(.smartScan),
                .protection,
                .performance,
                .appleFeatures
            ])
        }
        if includingCollapsed || applicationsExpanded {
            sections.append(contentsOf: [
                .apps,
                .appUpdates,
                .orphans
            ])
        }
        if includingCollapsed || toolsExpanded {
            sections.append(contentsOf: [
                .spaceExplorer,
                .duplicates,
                .similarPhotos
            ])
            if includingCollapsed || cleanupExpanded {
                sections.append(contentsOf: Self.cleanupCategories.map(AppSection.cleaning))
            }
            if includingCollapsed || advancedToolsExpanded {
                sections.append(contentsOf: Self.advancedCategories.map(AppSection.cleaning))
            }
        }
        sections.append(.settings)
        return sections
    }

    private func selectSection(_ section: AppSection) {
        navigationHistory.removeAll()
        selectedSection = section
        focusedSection = section
    }

    private func navigateFromCurrentSection(to section: AppSection) {
        guard selectedSection != section else { return }
        if let selectedSection { navigationHistory.append(selectedSection) }
        selectedSection = section
        focusedSection = section
    }

    private func showToolSwitcher() {
        guard !showsToolSwitcher, let window = NSApp.keyWindow,
              window.attachedSheet == nil, window.sheetParent == nil else { return }
        returnFocus = ToolReturnFocus(window: window)
        showsToolSwitcher = true
    }

    private func finishToolSwitch() {
        if let section = toolDestination {
            selectSection(section)
        } else {
            returnFocus?.restore()
        }
        toolDestination = nil
        returnFocus = nil
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = sections(includingCollapsed: false)
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
        switch appState.scanState {
        case .scanning: return String(localized: "Scanning")
        case .cleaning: return String(localized: "Cleaning")
        default: return nil
        }
    }

    private func sizeBadge(for category: CleaningCategory) -> String? {
        guard let size = appState.categoryResults[category]?.totalSize, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            navRow(.settings)
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(selectedSection == .settings ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            if selectedSection != .settings && selectedSection != .cleaning(.smartScan) && !appState.hasFullDiskAccess && !appState.fdaBannerDismissed {
                accessBanner
                    .transition(motionEnabled ? .move(edge: .top).combined(with: .opacity) : .identity)
            }
            detailView
                .id(selectedSection)
                .transition(motionEnabled ? .opacity.combined(with: .offset(y: 6)) : .identity)
        }
        .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: selectedSection)
        .animation(motionEnabled ? MotionTokens.gentle : nil, value: appState.fdaBannerDismissed)
        .animation(motionEnabled ? MotionTokens.gentle : nil, value: appState.hasFullDiskAccess)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showToolSwitcher) {
                    Label("Find a Tool", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(Text(verbatim: "\(String(localized: "Find a Tool")) (⌘K)"))
                .accessibilityIdentifier("toolbar.toolSwitcher")
            }
            ToolbarItem(placement: .navigation) {
                if !navigationHistory.isEmpty {
                    Button {
                        guard let previous = navigationHistory.popLast() else { return }
                        selectedSection = previous
                        focusedSection = previous
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .help("Back")
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .apps:
            AppListView()
        case .orphans:
            OrphanListView()
        case .spaceExplorer:
            SpaceExplorerView(
                model: spaceExplorer,
                findDuplicates: { folder in
                    duplicateFinder.startScan(folder)
                    navigateFromCurrentSection(to: .duplicates)
                },
                canFindDuplicates: !duplicateFinder.isMovingToTrash
            )
        case .duplicates:
            DuplicateFinderView(model: duplicateFinder)
        case .similarPhotos:
            SimilarPhotosView(model: similarPhotos)
        case .protection:
            ProtectionView()
        case .performance:
            PerformanceView()
        case .appleFeatures:
            AppleFeaturesView()
        case .appUpdates:
            AppUpdatesView()
        case .settings:
            SettingsView()
        case .cleaning(let category):
            if category == .smartScan {
                DashboardView(filters: dashboardFilters) { navigateFromCurrentSection(to: $0) }
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView(
                "PureMac",
                systemImage: "internaldrive",
                description: "Select a tool from the sidebar."
            )
        }
    }

    private var accessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(.subheadline.weight(.medium))
                Text("Protected caches and app containers will be skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up") {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            }
            .controlSize(.small)
            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ToolReturnFocus {
    weak var window: NSWindow?
    weak var view: NSView?

    init(window: NSWindow) {
        self.window = window
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSView {
            view = control
        } else {
            view = window.firstResponder as? NSView
        }
    }

    func restore() {
        guard let window, let view, view.window === window else { return }
        window.makeFirstResponder(view)
    }
}
