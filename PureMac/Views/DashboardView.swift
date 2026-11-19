import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    var onNavigate: (AppSection) -> Void = { _ in }

    @State private var showConfirmation = false
    @State private var hoveredSegment: String?
    @State private var pendingCleanItems: [CleanableItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                stateContent
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            cleanConfirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean selected items", role: .destructive) {
                appState.cleanAll(itemIDs: Set(pendingCleanItems.map(\.id)))
                pendingCleanItems = []
            }
            Button("Cancel", role: .cancel) {
                pendingCleanItems = []
            }
        } message: {
            Text(cleanConfirmationMessage)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Overview")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.45)
                    .accessibilityAddTraits(.isHeader)
                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 7) {
                let status = headerStatus
                StatusChip(label: status.label, systemImage: status.icon, tint: status.tint)
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(lastCareText(relativeTo: timeline.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch appState.scanState {
        case .idle:
            idleContent
                .transition(stateTransition)
        case .scanning:
            scanningContent
                .transition(stateTransition)
        case .completed:
            resultsContent
                .transition(stateTransition)
        case .cleaning:
            cleaningContent
                .transition(stateTransition)
        case .cleaned:
            cleanedContent
                .transition(stateTransition)
        }
    }

    private var stateTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5))
    }

    private var headerSubtitle: String {
        switch appState.scanState {
        case .idle:
            return String(localized: "Storage, cleanup, and system tools.")
        case .scanning:
            return String(localized: "Checking your Mac. Nothing is removed during a scan.")
        case .completed:
            return appState.scanWasCancelled
                ? String(localized: "The scan stopped. Available results are ready to review.")
                : String(localized: "Review the results and choose exactly what to remove.")
        case .cleaning:
            return String(localized: "Removing the items you selected.")
        case .cleaned:
            return String(localized: "Cleanup finished and disk information is refreshing.")
        }
    }

    private var headerStatus: (label: String, icon: String, tint: Color) {
        switch appState.scanState {
        case .idle:
            return appState.hasFullDiskAccess
                ? (String(localized: "Ready"), "checkmark.circle.fill", Tint.green)
                : (String(localized: "Limited access"), "lock.fill", Tint.orange)
        case .scanning:
            return (String(localized: "Scanning"), "magnifyingglass", Tint.accent)
        case .completed:
            if appState.scanWasCancelled {
                return (String(localized: "Stopped"), "stop.circle.fill", Tint.orange)
            }
            return (String(localized: "Review ready"), "checklist", Tint.accent)
        case .cleaning:
            return (String(localized: "Cleaning"), "trash.fill", Tint.orange)
        case .cleaned:
            return appState.lastCleanupHadFailures
                ? (String(localized: "Needs attention"), "exclamationmark.circle.fill", Tint.orange)
                : (String(localized: "Complete"), "checkmark.circle.fill", Tint.green)
        }
    }

    private func lastCareText(relativeTo now: Date) -> String {
        let date = appState.lastCleanedDate ?? appState.lastScanDate
        guard let date else {
            return String(localized: "No scan run yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(format: String(localized: "Last activity: %@"), relative)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            diskOverview
            scanIntroduction

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    dashboardSection("Storage")
                    CardSurface(padding: 0, elevation: .flat) {
                        VStack(spacing: 0) {
                            DashboardToolCard(
                                title: "Space Explorer",
                                detail: "Browse folders by size",
                                icon: "square.3.layers.3d.down.right",
                                tint: Tint.accent
                            ) { onNavigate(.spaceExplorer) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "Duplicate Finder",
                                detail: "Review files with identical contents",
                                icon: "doc.on.doc",
                                tint: Tint.accent
                            ) { onNavigate(.duplicates) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "Similar Photos",
                                detail: "Compare possible matches",
                                icon: "photo.stack",
                                tint: Tint.accent
                            ) { onNavigate(.similarPhotos) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 10) {
                    dashboardSection("Applications & system")
                    CardSurface(padding: 0, elevation: .flat) {
                        VStack(spacing: 0) {
                            DashboardToolCard(
                                title: "Apple Features",
                                detail: "Review Siri, image creation, and extras",
                                icon: "switch.2",
                                tint: Tint.accent
                            ) { onNavigate(.appleFeatures) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "Uninstaller",
                                detail: "Remove apps and related files",
                                icon: "app.dashed",
                                tint: Tint.accent
                            ) { onNavigate(.apps) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "App Updates",
                                detail: "Check Homebrew-managed apps",
                                icon: "arrow.triangle.2.circlepath",
                                tint: Tint.accent
                            ) { onNavigate(.appUpdates) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "Protection",
                                detail: "Check macOS security settings",
                                icon: "shield.checkered",
                                tint: Tint.accent
                            ) { onNavigate(.protection) }
                            Divider().padding(.leading, 46)
                            DashboardToolCard(
                                title: "Performance",
                                detail: "View processes and startup items",
                                icon: "gauge.with.dots.needle.67percent",
                                tint: Tint.accent
                            ) { onNavigate(.performance) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var scanIntroduction: some View {
        CardSurface(padding: 18, elevation: .flat) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review cleanup")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Check \(CleaningCategory.scannable.count) categories for caches, logs, and other removable files. Review the results before deleting anything.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appState.startSmartScan()
                } label: {
                    Label("Scan this Mac", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Tint.accent)
                .accessibilityIdentifier("dashboard.scan")
            }
        }
    }

    private var diskOverview: some View {
        CardSurface(padding: 20, elevation: .flat) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac storage")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(appState.diskInfo.formattedFree)
                                .font(.system(size: 26, weight: .semibold))
                                .monospacedDigit()
                            Text("available")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(usedPercent)% used")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        appState.loadDiskInfo()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh disk information")
                    .accessibilityLabel("Refresh disk information")
                }

                StackedMeter(
                    segments: diskSegments.map {
                        StackedMeter.Segment(id: $0.id, value: $0.value, color: $0.color)
                    },
                    height: 10,
                    highlightedID: hoveredSegment
                )
                .accessibilityHidden(true)

                HStack(spacing: 24) {
                    diskLegendRow(
                        id: "used",
                        color: Color.primary.opacity(0.56),
                        label: "Used",
                        value: ByteCountFormatter.string(
                            fromByteCount: max(0, appState.diskInfo.usedSpace - appState.diskInfo.purgeableSpace),
                            countStyle: .file
                        )
                    )
                    if appState.diskInfo.purgeableSpace > 0 {
                        diskLegendRow(
                            id: "purgeable",
                            color: Tint.cyan,
                            label: "Purgeable",
                            value: appState.diskInfo.formattedPurgeable
                        )
                    }
                    diskLegendRow(
                        id: "free",
                        color: Tint.accent,
                        label: "Available",
                        value: appState.diskInfo.formattedFree
                    )
                }

                if appState.diskInfo.purgeableSpace > 0 {
                    Text("Purgeable space is managed by macOS and is not included in cleanup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func diskLegendRow(id: String, color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .opacity(hoveredSegment == nil || hoveredSegment == id ? 1 : 0.38)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                hoveredSegment = hovering ? id : nil
            }
        }
    }

    private var diskSegments: [StorageDonut.Segment] {
        let info = appState.diskInfo
        let used = max(0, info.usedSpace - info.purgeableSpace)
        var segments = [
            StorageDonut.Segment(
                id: "used",
                value: Double(used),
                color: Color.primary.opacity(0.56),
                label: "Used",
                display: ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
            )
        ]
        if info.purgeableSpace > 0 {
            segments.append(
                StorageDonut.Segment(
                    id: "purgeable",
                    value: Double(info.purgeableSpace),
                    color: Tint.cyan,
                    label: "Purgeable",
                    display: info.formattedPurgeable
                )
            )
        }
        segments.append(
            StorageDonut.Segment(
                id: "free",
                value: Double(max(0, info.freeSpace)),
                color: Tint.accent,
                label: "Available",
                display: info.formattedFree
            )
        )
        return segments
    }

    private var usedPercent: Int {
        guard appState.diskInfo.totalSpace > 0 else { return 0 }
        let used = appState.diskInfo.totalSpace - appState.diskInfo.freeSpace
        return Int((Double(max(0, used)) / Double(appState.diskInfo.totalSpace) * 100).rounded())
    }

    private var scanningContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardSurface(padding: 20, elevation: .flat) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Scanning your Mac")
                                .font(.system(size: 18, weight: .semibold))
                            Text(LocalizedStringKey(appState.currentScanCategory))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(appState.scanProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 18, weight: .medium))
                            .monospacedDigit()
                    }
                    ProgressView(value: appState.scanProgress)
                        .progressViewStyle(.linear)
                        .tint(Tint.accent)
                    ScanPathTicker(ticker: appState.scanTicker)
                    HStack(spacing: 10) {
                        Button("Stop scan", role: .cancel) {
                            appState.cancelScan()
                        }
                        .buttonStyle(.bordered)
                        Text("Stopping keeps the results found so far.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !appState.allResults.isEmpty {
                dashboardSection("Found so far", detail: "\(appState.totalItemCount) items")
                resultRows(results: Array(appState.allResults.sorted { $0.totalSize > $1.totalSize }.prefix(6)))
            }
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardSurface(padding: 20, elevation: .flat) {
                HStack(alignment: .center, spacing: 24) {
                    IconTile(
                        systemName: appState.scanWasCancelled ? "stop.circle" : "checklist",
                        tint: appState.scanWasCancelled ? Tint.orange : Tint.accent,
                        size: 32,
                        corner: 8
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(appState.scanWasCancelled ? "Scan stopped" : "Scan complete")
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.3)
                        Text(resultSummary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Selected")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        CountUpBytes(bytes: appState.totalSelectedSize)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                    }

                    VStack(spacing: 8) {
                        if appState.totalSelectedSize > 0 {
                            Button {
                                prepareCleanupConfirmation()
                            } label: {
                                Label(cleanSelectedLabel, systemImage: "trash")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(Tint.accent)
                        }
                        Button("Scan again") {
                            appState.startSmartScan()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if appState.allResults.isEmpty {
                emptyResults
            } else {
                dashboardSection(
                    appState.scanWasCancelled ? "Partial results" : "Cleanup plan",
                    detail: "Open a category to review individual items"
                )
                resultRows(results: appState.allResults.sorted { $0.totalSize > $1.totalSize })
            }
        }
    }

    private var resultSummary: String {
        if appState.allResults.isEmpty {
            return appState.scanWasCancelled
                ? String(localized: "No reclaimable items were found before the scan stopped.")
                : String(localized: "No reclaimable items were found in the areas checked.")
        }
        let size = ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
        if appState.scanWasCancelled {
            return String(format: String(localized: "%@ found before the scan stopped. Results may be incomplete."), size)
        }
        return String(format: String(localized: "%@ found across %lld categories."), size, Int64(appState.allResults.count))
    }

    private var emptyResults: some View {
        CardSurface(padding: 28, elevation: .flat) {
            HStack(spacing: 18) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.scanWasCancelled ? "No results yet" : "Nothing to clean")
                        .font(.system(size: 18, weight: .semibold))
                    Text(
                        appState.scanWasCancelled
                            ? "Run the scan again when you are ready to check every area."
                            : "PureMac did not find removable items in the selected scan areas."
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func resultRows(results: [CategoryResult]) -> some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    CategoryResultRow(
                        result: result,
                        selectedCount: appState.selectedCountInCategory(result.category),
                        selection: appState.categoryBinding(for: result.category)
                    ) {
                        onNavigate(.cleaning(result.category))
                    }
                    if index < results.count - 1 {
                        Divider()
                            .padding(.leading, 58)
                    }
                }
            }
        }
    }

    private var cleaningContent: some View {
        CardSurface(padding: 20, elevation: .flat) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Cleaning selected items")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text(appState.cleanProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 18, weight: .medium))
                        .monospacedDigit()
                }
                ProgressView(value: appState.cleanProgress)
                    .tint(Tint.accent)
                Text("Keep PureMac open until cleanup finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cleanedContent: some View {
        CardSurface(padding: 24, elevation: .flat) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: appState.lastCleanupHadFailures ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(appState.lastCleanupHadFailures ? Tint.orange : Tint.accent)
                VStack(alignment: .leading, spacing: 9) {
                    Text(appState.lastCleanupHadFailures ? "Some items need attention" : "Cleanup complete")
                        .font(.system(size: 20, weight: .semibold))
                    if appState.totalFreedSpace > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: appState.totalFreedSpace, countStyle: .file)) removed")
                            .font(.system(size: 16, weight: .medium))
                            .monospacedDigit()
                    }
                    if let cleanError = appState.cleanError {
                        Text(cleanError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Button("Done") {
                        appState.scanState = .idle
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.accent)
                    .padding(.top, 5)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cleanConfirmationTitle: String {
        let size = pendingCleanItems.reduce(Int64(0)) { $0 + $1.size }
        return String(
            format: String(localized: "Permanently delete %@?"),
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        )
    }

    private var cleanConfirmationMessage: String {
        String(
            format: String(localized: "%lld selected items will be permanently deleted. Review the list before continuing."),
            Int64(pendingCleanItems.count)
        )
    }

    private func prepareCleanupConfirmation() {
        pendingCleanItems = appState.allResults
            .flatMap(\.items)
            .filter(appState.isItemSelected)
        showConfirmation = !pendingCleanItems.isEmpty
    }

    private var cleanSelectedLabel: String {
        String(
            format: String(localized: "Clean %@"),
            ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file)
        )
    }

    private func dashboardSection(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct DashboardToolCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(hovering ? tint : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovering ? Color.primary.opacity(0.035) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct CategoryResultRow: View {
    let result: CategoryResult
    let selectedCount: Int
    @Binding var selection: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $selection)
                .labelsHidden()
                .toggleStyle(AnimatedCheckboxStyle(tint: Tint.accent))
            IconTile(systemName: result.category.icon, tint: result.category.color, size: 30, corner: 8)
            Button(action: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(result.category.rawValue))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(selectedCount) of \(result.itemCount) selected")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(result.formattedSize)
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct ScanPathTicker: View {
    @ObservedObject var ticker: ScanProgressTicker

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
            Text(ticker.path.isEmpty ? String(localized: "Preparing the next area…") : ticker.path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .accessibilityLabel("Current scan path")
        .accessibilityValue(ticker.path)
    }
}
