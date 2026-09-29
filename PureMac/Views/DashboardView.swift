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
                Text("Smart Care")
                    .font(.system(size: 28, weight: .semibold))
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
            return String(localized: "A clear view of reclaimable storage and the tools that manage it.")
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
            GeometryReader { geometry in
                let diskWidth = min(390, max(286, geometry.size.width * 0.38))
                HStack(alignment: .top, spacing: 14) {
                    scanIntroduction
                        .frame(width: geometry.size.width - diskWidth - 14, height: 246)
                    diskOverview
                        .frame(width: diskWidth, height: 246)
                }
            }
            .frame(height: 246)

            dashboardSection("Tools", detail: "Focused utilities for storage, apps, and system maintenance")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)],
                spacing: 14
            ) {
                DashboardToolCard(
                    title: "Space Explorer",
                    detail: "Find what uses the most disk space",
                    icon: "square.3.layers.3d.down.right",
                    tint: Tint.accent
                ) {
                    onNavigate(.spaceExplorer)
                }
                DashboardToolCard(
                    title: "Duplicate Finder",
                    detail: "Review matching files side by side",
                    icon: "doc.on.doc",
                    tint: Tint.purple
                ) {
                    onNavigate(.duplicates)
                }
                DashboardToolCard(
                    title: "Similar Photos",
                    detail: "Compare visually similar photos",
                    icon: "photo.stack",
                    tint: Tint.pink
                ) {
                    onNavigate(.similarPhotos)
                }
                DashboardToolCard(
                    title: "Uninstaller",
                    detail: "Remove apps and their related files",
                    icon: "app.dashed",
                    tint: Tint.blue
                ) {
                    onNavigate(.apps)
                }
                DashboardToolCard(
                    title: "App Updates",
                    detail: "Check installed apps for new versions",
                    icon: "arrow.triangle.2.circlepath",
                    tint: Tint.accent
                ) {
                    onNavigate(.appUpdates)
                }
                DashboardToolCard(
                    title: "Protection",
                    detail: "Review built-in privacy and safety checks",
                    icon: "shield.checkered",
                    tint: Tint.green
                ) {
                    onNavigate(.protection)
                }
                DashboardToolCard(
                    title: "Performance",
                    detail: "Inspect memory and background activity",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: Tint.cyan
                ) {
                    onNavigate(.performance)
                }
            }
        }
    }

    private var scanIntroduction: some View {
        CardSurface(padding: 24, elevation: .standard, tint: Tint.accent) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    IconTile(systemName: "sparkles", tint: Tint.accent, size: 38, corner: 10, vivid: true)
                    Spacer()
                    Text("\(CleaningCategory.scannable.count) areas")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Find space to reclaim.")
                        .font(.system(size: 25, weight: .semibold))
                        .tracking(-0.35)
                    Text("PureMac checks caches, logs, developer data, downloads, and Trash. You review the result before anything is removed.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        appState.startSmartScan()
                    } label: {
                        Label("Scan this Mac", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Tint.accent)

                    Label("Local and private", systemImage: "lock")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var diskOverview: some View {
        CardSurface(padding: 22, elevation: .standard) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac storage")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(appState.diskInfo.formattedFree) available")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.loadDiskInfo()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh disk information")
                }

                HStack(spacing: 16) {
                    ZStack {
                        StorageDonut(
                            segments: diskSegments,
                            lineWidth: 13,
                            highlightedID: hoveredSegment
                        )
                        VStack(spacing: 0) {
                            Text("\(usedPercent)%")
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("USED")
                                .font(.system(size: 8.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 108, height: 108)

                    VStack(alignment: .leading, spacing: 12) {
                        diskLegendRow(
                            id: "used",
                            color: Color.primary.opacity(0.56),
                            label: "Used",
                            value: appState.diskInfo.formattedUsed
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
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            CardSurface(padding: 28, elevation: .standard, tint: Tint.accent) {
                HStack(spacing: 34) {
                    ScanningGauge(progress: appState.scanProgress, tint: Tint.accent)
                        .frame(width: 164, height: 164)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scanning your Mac")
                            .font(.system(size: 25, weight: .semibold))
                            .tracking(-0.35)
                        Text(appState.currentScanCategory)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Tint.accent)
                        ScanPathTicker(ticker: appState.scanTicker)
                            .frame(maxWidth: 520, alignment: .leading)
                        ProgressView(value: appState.scanProgress)
                            .progressViewStyle(.linear)
                            .tint(Tint.accent)
                            .frame(maxWidth: 480)
                        HStack(spacing: 10) {
                            Button("Stop scan", role: .cancel) {
                                appState.cancelScan()
                            }
                            .buttonStyle(.bordered)
                            Text("Stopping keeps the results found so far.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
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
            CardSurface(padding: 24, elevation: .standard, tint: appState.scanWasCancelled ? Tint.orange : Tint.accent) {
                HStack(alignment: .center, spacing: 24) {
                    IconTile(
                        systemName: appState.scanWasCancelled ? "stop.circle" : "checklist",
                        tint: appState.scanWasCancelled ? Tint.orange : Tint.accent,
                        size: 52,
                        corner: 14
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(appState.scanWasCancelled ? "Scan stopped" : "Scan complete")
                            .font(.system(size: 23, weight: .semibold))
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
                SuccessMedal(tint: Tint.green, size: 72)
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
        CardSurface(padding: 34, elevation: .standard, tint: Tint.accent) {
            VStack(spacing: 22) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.accent, label: "CLEANING")
                    .frame(width: 170, height: 170)
                VStack(spacing: 6) {
                    Text("Cleaning selected items")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Keep PureMac open until this pass finishes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: appState.cleanProgress)
                    .tint(Tint.accent)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, minHeight: 380)
        }
    }

    private var cleanedContent: some View {
        CardSurface(
            padding: 38,
            elevation: .standard,
            tint: appState.lastCleanupHadFailures ? Tint.orange : Tint.green
        ) {
            HStack(spacing: 34) {
                SuccessMedal(tint: appState.lastCleanupHadFailures ? Tint.orange : Tint.green, size: 126)
                VStack(alignment: .leading, spacing: 9) {
                    Text(appState.lastCleanupHadFailures ? "Some items need attention" : "Cleanup complete")
                        .font(.system(size: 25, weight: .semibold))
                    if appState.totalFreedSpace > 0 {
                        CountUpBytes(bytes: appState.totalFreedSpace)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                        Text("reclaimed")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
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
                    .controlSize(.large)
                    .tint(Tint.accent)
                    .padding(.top, 5)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .leading)
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
            CardSurface(padding: 16, elevation: .flat, tint: hovering ? tint : nil) {
                HStack(spacing: 12) {
                    IconTile(systemName: icon, tint: tint, size: 36, corner: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
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
