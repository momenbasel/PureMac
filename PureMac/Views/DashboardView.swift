import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var filters = DashboardResultsFilters()
    var onNavigate: (AppSection) -> Void = { _ in }

    @State private var pendingReview: CleanupSelection?
    @State private var showsScope = false
    @State private var visibleItemCount = 20
    @State private var searchResult: DashboardSearchResult?
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        let reviewing = appState.scanState == .completed
        let categories = reviewing ? appState.allResults : []
        let scope = categories.contains { $0.category == filters.categoryScope } ? filters.categoryScope : nil
        let key = DashboardSearchKey(categories: categories.map(\.id), scope: scope, text: filters.query.trimmingCharacters(in: .whitespacesAndNewlines))
        let matches = searchResult?.key == key ? searchResult : nil
        let review = DashboardReviewRows(categories: categories, matches: matches, selectedOnly: filters.selectedOnly, isSelected: appState.cleanupRowSelection.isSelected)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: reviewing ? 17 : 21) {
                    header.id("overview-top")
                    if !reviewing {
                        storageStrip
                    }
                    Group {
                        if reviewing {
                            resultsContent(review: review, categories: categories, loading: matches == nil && !categories.isEmpty)
                        } else {
                            stateContent
                        }
                    }
                        .id(titleKey)
                        .transition(motionEnabled ? .opacity : .identity)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(motionEnabled ? .easeOut(duration: 0.2) : nil, value: titleKey)
            }
            .onChange(of: title) { _ in
                proxy.scrollTo("overview-top", anchor: .top)
                headingFocused = true
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if reviewing {
                selectionBar(review: review, loading: matches == nil && !categories.isEmpty)
            }
        }
        .task(id: key) {
            guard reviewing else { return }
            if filters.categoryScope != scope { filters.categoryScope = scope }
            if let result = await filters.index.match(key: key, categories: categories), !Task.isCancelled {
                searchResult = result
            }
        }
        .onAppear { filters.synchronize(scanDate: appState.lastScanDate) }
        .onChange(of: appState.lastScanDate) { filters.synchronize(scanDate: $0) }
        .onChange(of: key) { _ in visibleItemCount = 20 }
        .onChange(of: filters.selectedOnly) { _ in visibleItemCount = 20 }
        .sheet(item: $pendingReview) { selection in
            CleanupReviewSheet(selection: selection, cancel: {
                pendingReview = nil
            }, confirm: {
                pendingReview = nil
                appState.cleanReviewed(selection)
            })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Spacer(minLength: 8)
            if let date = appState.lastScanDate {
                HStack(spacing: 4) {
                    Text("Last scan")
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .help(date.formatted())
            }
        }
    }

    private var title: LocalizedStringKey { LocalizedStringKey(titleKey) }

    private var titleKey: String {
        switch appState.scanState {
        case .idle: return "Overview"
        case .scanning: return "Scanning your Mac"
        case .completed: return appState.scanWasCancelled ? "Scan stopped" : "Scan results"
        case .cleaning: return "Cleaning selected items"
        case .cleaned: return appState.lastCleanupHadFailures ? "Some items need attention" : "Cleanup complete"
        }
    }

    private var storageStrip: some View {
        let disk = appState.diskInfo
        let volume = StartupVolumeInfo.current
        let used = max(0, disk.usedSpace - disk.purgeableSpace)
        return HStack(alignment: .center, spacing: 15) {
            Image(nsImage: volume.icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 61, height: 61)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: volume.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: appState.loadDiskInfo) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh disk information")
                    .help("Refresh disk information")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Startup disk")
                    Spacer(minLength: 0)
                    if disk.totalSpace > 0 {
                        Text("\(disk.formattedFree) available of \(disk.formattedTotal)")
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if disk.totalSpace > 0 {
                    GeometryReader { geometry in
                        let total = CGFloat(disk.totalSpace)
                        HStack(spacing: 0) {
                            Rectangle().fill(Color(nsColor: .secondaryLabelColor))
                                .frame(width: geometry.size.width * min(1, CGFloat(used) / total))
                            Rectangle().fill(Color(nsColor: .tertiaryLabelColor))
                                .frame(width: geometry.size.width * min(1, CGFloat(disk.purgeableSpace) / total))
                            Color(nsColor: .quaternaryLabelColor)
                        }
                    }
                    .frame(height: 7)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    HStack(spacing: 16) {
                        storageLegend("Used", bytes: used, color: Color(nsColor: .secondaryLabelColor))
                        if disk.purgeableSpace > 0 {
                            storageLegend("Purgeable", bytes: disk.purgeableSpace, color: Color(nsColor: .tertiaryLabelColor))
                                .help("Purgeable space is managed by macOS and is not included in cleanup.")
                                .accessibilityHint("Purgeable space is managed by macOS and is not included in cleanup.")
                        }
                    }
                } else {
                    Text("Storage details unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func storageLegend(_ label: LocalizedStringKey, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(label)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch appState.scanState {
        case .idle:
            idleContent
        case .scanning:
            progressContent
        case .completed:
            EmptyView()
        case .cleaning:
            ProgressView(value: appState.cleanProgress) {
                Text("Keep PureMac open until cleanup finishes.")
            }
        case .cleaned:
            receiptContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Scan").font(.title3.weight(.semibold))
                    Text("Check caches, logs, and other removable files without changing them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Scan this Mac", action: startScan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(appState.deviceBackupRemovalInProgress)
                    .accessibilityIdentifier("dashboard.scan")
            }
            scopeDisclosure
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Tools").font(.headline).accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 5)
                toolRow("Space Explorer", detail: "Browse folders by size", symbol: "folder", section: .spaceExplorer)
                Divider()
                toolRow("Installed Apps", detail: "Remove apps and related files", symbol: "app.dashed", section: .apps)
            }
            if !appState.allResults.isEmpty {
                Button("Review scan results") { appState.scanState = .completed }
            }
            if let receipt = appState.lastCleanupReceipt {
                DisclosureGroup("Last cleanup receipt") {
                    CleanupReceiptView(receipt: receipt)
                        .padding(.top, 8)
                }
                .accessibilityIdentifier("dashboard.lastReceipt")
            }
        }
    }

    private func toolRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, section: AppSection) -> some View {
        Button {
            onNavigate(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 6)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 37)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scopeDisclosure: some View {
        DisclosureGroup(isExpanded: $showsScope) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(appState.scanCategories) { category in
                    Label(LocalizedStringKey(category.rawValue), systemImage: category.icon)
                        .font(.callout)
                }
            }
            .padding(.vertical, 10)
        } label: {
            HStack {
                Text("Scan scope")
                Spacer()
                Group {
                    if appState.scanCategories.count == 1, let category = appState.scanCategories.first {
                        Text(LocalizedStringKey(category.rawValue))
                    } else {
                        Text("\(appState.scanCategories.count) areas")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func startScan() {
        clearFilters()
        visibleItemCount = 20
        appState.startSmartScan()
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(appState.currentScanCategory.isEmpty ? "Preparing scan" : appState.currentScanCategory))
                    .font(.headline)
                Spacer()
                Text(appState.scanProgress, format: .percent.precision(.fractionLength(0)))
                    .font(.body.monospacedDigit())
                Button("Stop scan", action: appState.cancelScan)
                    .accessibilityIdentifier("dashboard.stop")
                    .help("Stopping keeps the results found so far.")
            }
            ProgressView(value: appState.scanProgress)
                .accessibilityLabel("Scanning your Mac")
            HStack {
                ScanPathTicker(ticker: appState.scanTicker)
                Spacer()
            }
            if !appState.allResults.isEmpty {
                Text("Found so far").font(.headline).padding(.top, 4)
                ForEach(rankedCategories.prefix(5)) { result in
                    HStack {
                        Text(LocalizedStringKey(result.category.rawValue))
                        Spacer()
                        Text(result.formattedSize).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var rankedCategories: [CategoryResult] {
        appState.allResults.sorted {
            if $0.totalSize == $1.totalSize { return $0.category.rawValue < $1.category.rawValue }
            return $0.totalSize > $1.totalSize
        }
    }

    private func selectionBar(review: DashboardReviewRows, loading: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(review.selected.count) of \(review.totalCount) selected")
                    .font(.headline)
                    .accessibilityIdentifier("dashboard.selection")
                if !review.selected.isEmpty {
                    Text("Estimated size: \(ByteCountFormatter.string(fromByteCount: review.selectedBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if review.hiddenSelected > 0 {
                    Label("Selected outside filters: \(review.hiddenSelected)", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Tint.orange)
                        .accessibilityIdentifier("dashboard.hiddenSelection")
                }
            }
            Spacer(minLength: 4)
            Button("Finish review") { appState.scanState = .idle }
                .accessibilityIdentifier("dashboard.finish")
            Button("Review selected") {
                guard !review.selected.isEmpty else { return }
                pendingReview = CleanupSelection(items: review.selected)
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || review.selected.isEmpty || appState.deviceBackupRemovalInProgress)
            .accessibilityIdentifier("dashboard.review")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func resultsContent(review: DashboardReviewRows, categories: [CategoryResult], loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !categories.isEmpty {
                DashboardCategoryEstimates(results: categories, scope: $filters.categoryScope)
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search names or paths", text: $filters.query)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("dashboard.search")
                        if !filters.query.isEmpty {
                            Button { filters.query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.16)) }
                    Toggle("Selected only", isOn: $filters.selectedOnly)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("dashboard.selectedOnly")
                }
                HStack(spacing: 10) {
                    Picker("Review by", selection: $filters.byCategory) {
                        Text("Largest items").tag(false)
                        Text("By category").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 2)
                    if hasFilters {
                        Button("Clear filters", action: clearFilters)
                            .buttonStyle(.link)
                            .accessibilityIdentifier("dashboard.clearFilters")
                    }
                    if !loading {
                        Text("Matching items: \(review.visible.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("dashboard.visibleCount")
                    }
                }
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if review.visible.isEmpty {
                    Text("No matching files").font(.headline).padding(.vertical, 8)
                } else if filters.byCategory {
                    categoryRows(review: review)
                } else {
                    itemRows(review.visible)
                }
            } else {
                Label(appState.scanWasCancelled ? "No results yet" : "Nothing to clean",
                      systemImage: appState.scanWasCancelled ? "stop.circle" : "checkmark.circle")
                    .font(.title3.weight(.semibold))
                Text(appState.scanWasCancelled
                     ? "No reclaimable items were found before the scan stopped."
                     : "No reclaimable items were found in the areas checked.")
                    .foregroundStyle(.secondary)
            }
            if !appState.hasFullDiskAccess {
                HStack(spacing: 10) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text("Protected caches and app containers will be skipped.")
                        .font(.callout)
                    Spacer()
                    Button("Set up") {
                        PermissionCoordinator.shared.requestAccess(context: .general) { appState.checkFullDiskAccess() }
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Set up Full Disk Access")
                }
                .foregroundStyle(.secondary)
            }
            Button("Scan again", action: startScan)
                .disabled(appState.deviceBackupRemovalInProgress)
                .accessibilityIdentifier("dashboard.rescan")
        }
    }

    private var hasFilters: Bool {
        !filters.query.isEmpty || filters.selectedOnly || filters.categoryScope != nil
    }

    private func clearFilters() {
        filters.clear()
    }

    private func itemRows(_ items: [CleanableItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(width: 112, alignment: .leading)
                Text("Size").frame(width: 76, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 42)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            Divider()
            ForEach(items.prefix(visibleItemCount)) { item in
                DashboardItemRow(item: item, available: appState.isCleanupItemAvailable(item), selected: appState.itemBinding(for: item))
                Divider()
            }
            if items.count > visibleItemCount {
                Button("Show more items") { visibleItemCount += 20 }
                    .padding(.top, 10)
            }
        }
    }

    private func categoryRows(review: DashboardReviewRows) -> some View {
        let grouped = Dictionary(grouping: review.visible, by: \.category)
        let availability = appState.cleanupRowSelection
        return VStack(spacing: 0) {
            ForEach(rankedCategories) { result in
                if let items = grouped[result.category] {
                    let chosen = items.filter { review.selectedIDs.contains($0.id) }.count
                    let hasBulkCandidate = items.contains { !$0.selectOnlyByHand && availability.isAvailable($0) }
                    HStack(spacing: 12) {
                        Toggle(LocalizedStringKey(result.category.rawValue), isOn: Binding(
                            get: { chosen > 0 },
                            set: { appState.setSelection($0, for: items) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(chosen == 0 && !hasBulkCandidate)
                        Button {
                            onNavigate(.cleaning(result.category))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey(result.category.rawValue)).font(.headline)
                                    Text("\(chosen) of \(items.count) selected")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file))
                                    .monospacedDigit()
                                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }
        }
    }

    private var receiptContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if !appState.allResults.isEmpty {
                    Button("Return to results") { appState.scanState = .completed }
                        .buttonStyle(.borderedProminent)
                        .tint(Tint.accent)
                        .accessibilityIdentifier("dashboard.remaining")
                }
                Button("Done") { appState.scanState = .idle }
                    .accessibilityIdentifier("dashboard.finish")
            }
            if let receipt = appState.lastCleanupReceipt {
                CleanupReceiptView(receipt: receipt)
            } else if let error = appState.cleanError {
                Text(error).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DashboardItemRow: View {
    let item: CleanableItem
    let available: Bool
    @Binding var selected: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Toggle(item.name, isOn: $selected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!available)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(item.category.description))
                    if !item.path.isEmpty {
                        Text(verbatim: item.path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.name)
                        if !available {
                            Text("Changed since review. Scan again to review this item.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(LocalizedStringKey(item.category.rawValue))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 112, alignment: .leading)
                    Text(item.formattedSize)
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }
}

private struct ScanPathTicker: View {
    @ObservedObject var ticker: ScanProgressTicker

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(ticker.path.isEmpty ? String(localized: "Preparing the next area…") : ticker.path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .accessibilityLabel("Current scan path")
        .accessibilityValue(ticker.path)
    }
}

struct DashboardSearchKey: Equatable {
    let categories: [UUID]
    let scope: CleaningCategory?
    let text: String
}

struct DashboardSearchResult {
    let key: DashboardSearchKey
    let items: [CleanableItem]
    let matchingIDs: Set<UUID>?
}

actor DashboardResultIndex {
    private var sourceIDs: [UUID] = []
    private var sorted: [CleanableItem] = []

    func match(key: DashboardSearchKey, categories: [CategoryResult]) -> DashboardSearchResult? {
        guard !Task.isCancelled else { return nil }
        if key.categories != sourceIDs {
            let items = categories.flatMap(\.items).sorted { left, right in
                if left.size != right.size { return left.size > right.size }
                let comparison = left.name.localizedStandardCompare(right.name)
                return comparison == .orderedSame ? left.path < right.path : comparison == .orderedAscending
            }
            guard !Task.isCancelled else { return nil }
            sorted = items
            sourceIDs = key.categories
        }
        if key.scope == nil && key.text.isEmpty {
            return DashboardSearchResult(key: key, items: sorted, matchingIDs: nil)
        }
        var items: [CleanableItem] = []
        var ids: Set<UUID> = []
        for item in sorted {
            if Task.isCancelled { return nil }
            guard key.scope == nil || item.category == key.scope else { continue }
            if !key.text.isEmpty && !item.name.localizedStandardContains(key.text) && !item.path.localizedStandardContains(key.text) {
                continue
            }
            items.append(item)
            ids.insert(item.id)
        }
        return DashboardSearchResult(key: key, items: items, matchingIDs: ids)
    }
}

struct DashboardReviewRows {
    let totalCount: Int
    let selected: [CleanableItem]
    let selectedIDs: Set<UUID>
    let selectedBytes: Int64
    let hiddenSelected: Int
    let visible: [CleanableItem]

    init(categories: [CategoryResult], matches: DashboardSearchResult?, selectedOnly: Bool, isSelected: (CleanableItem) -> Bool) {
        totalCount = categories.reduce(0) { $0 + $1.itemCount }
        let chosen = categories.flatMap { $0.items.filter(isSelected) }
        let ids = Set(chosen.map(\.id))
        selected = chosen
        selectedIDs = ids
        selectedBytes = chosen.reduce(0) { $0 + $1.size }
        if let matchingIDs = matches?.matchingIDs {
            hiddenSelected = ids.reduce(0) { $0 + (matchingIDs.contains($1) ? 0 : 1) }
        } else {
            hiddenSelected = 0
        }
        let items = matches?.items ?? []
        visible = selectedOnly ? items.filter { ids.contains($0.id) } : items
    }
}

private struct DashboardCategoryEstimates: View {
    let results: [CategoryResult]
    @Binding var scope: CleaningCategory?

    var body: some View {
        let ranked = results.sorted {
            if $0.totalSize == $1.totalSize { return $0.category.rawValue < $1.category.rawValue }
            return $0.totalSize > $1.totalSize
        }
        let largest = max(ranked.first?.totalSize ?? 0, 1)
        let featured = featuredCategories(ranked)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Category estimates")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("By category", selection: $scope) {
                    Text("All categories").tag(Optional<CleaningCategory>.none)
                    ForEach(ranked) { result in
                        Text(LocalizedStringKey(result.category.rawValue)).tag(Optional(result.category))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("dashboard.category")
            }
            ForEach(featured) { result in
                let category = result.category
                let focused = category == scope
                Button {
                    scope = focused ? nil : category
                } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: focused ? "checkmark" : category.icon)
                                .font(.caption)
                                .frame(width: 15)
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(category.rawValue)).lineLimit(1)
                        }
                        .frame(width: 154, alignment: .leading)
                        .foregroundStyle(focused ? Color.accentColor : .primary)
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(focused ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                                .frame(width: geometry.size.width * CGFloat(result.totalSize) / CGFloat(largest))
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                        Text(result.formattedSize)
                            .monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(focused ? .isSelected : [])
                .accessibilityIdentifier("dashboard.scope.\(category.id)")
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider() }
        .help("Each bar compares its category with the largest estimate. Categories can overlap.")
    }

    private func featuredCategories(_ ranked: [CategoryResult]) -> [CategoryResult] {
        var featured = Array(ranked.prefix(3))
        if let scope, !featured.contains(where: { $0.category == scope }),
           let scoped = ranked.first(where: { $0.category == scope }) {
            featured[featured.count - 1] = scoped
        }
        return featured
    }
}

final class DashboardResultsFilters: ObservableObject {
    @Published var query = ""
    @Published var categoryScope: CleaningCategory?
    @Published var selectedOnly = false
    @Published var byCategory = false
    let index = DashboardResultIndex()
    private var lastScanDate: Date?

    func clear() {
        if !query.isEmpty { query = "" }
        if selectedOnly { selectedOnly = false }
        if categoryScope != nil { categoryScope = nil }
    }

    func synchronize(scanDate: Date?) {
        guard lastScanDate != scanDate else { return }
        lastScanDate = scanDate
        clear()
    }
}
