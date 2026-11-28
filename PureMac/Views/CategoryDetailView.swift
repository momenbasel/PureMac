import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    let category: CleaningCategory

    @State private var filter = CleanupReviewFilter()
    @StateObject private var browser = CategoryFilterState()
    @State private var pendingReview: CleanupSelection?
    @State private var showingReceipt = false

    private var result: CategoryResult? { appState.categoryResults[category] }
    private var filterKey: CategoryFilterKey? {
        result.map { CategoryFilterKey(resultID: $0.id, filter: filter) }
    }

    var body: some View {
        let key = filterKey
        let ready = browser.rows(for: key)
        return VStack(spacing: 0) {
            header
            if case .scanning = appState.scanState {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(Text(LocalizedStringKey(appState.currentScanCategory)))…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop scan") { appState.cancelScan() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            if case .cleaning(let progress) = appState.scanState {
                HStack {
                    Label(appState.isAuthorizingCleanup ? "Waiting for administrator approval" : "Cleaning",
                          systemImage: appState.isAuthorizingCleanup ? "lock" : "trash")
                        .font(.callout.weight(.medium))
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            if appState.lastCleanupCategory == category, let receipt = appState.lastCleanupReceipt {
                if result?.items.isEmpty != false {
                    ScrollView { CleanupReceiptView(receipt: receipt).padding(28) }
                } else {
                    DisclosureGroup("Cleanup receipt", isExpanded: $showingReceipt) {
                        ScrollView { CleanupReceiptView(receipt: receipt).padding(.top, 8) }
                            .frame(maxHeight: 210)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                }
            }
            if let result, !result.items.isEmpty {
                let summary = selectionSummary(for: result.items, visibleIDs: ready?.ids)
                filters(ready, summary: summary)
                Divider()
                if let ready {
                    if ready.items.isEmpty {
                        EmptyStateView("No matching files", systemImage: "line.3.horizontal.decrease.circle", description: "Try another name, size, or date range.", action: { filter = CleanupReviewFilter() }, actionLabel: "Clear filters", tint: .accentColor)
                    } else {
                        List(ready.items) { item in
                            CleanupFileRow(item: item)
                                .listRowSeparator(.visible)
                        }
                        .listStyle(.inset)
                        .disabled(appState.scanState.isActive)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Filter cleanup files")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                selectionBar(summary, rows: ready)
            } else if appState.lastCleanupCategory == category {
                Spacer(minLength: 0)
            } else if result != nil {
                EmptyStateView("No files found", systemImage: "checkmark.circle", description: appState.hasFullDiskAccess ? "There are no cleanup items in this category." : "Some protected locations are unavailable. Full Disk Access allows a more complete scan.", tint: .accentColor)
            } else if !appState.scanState.isActive {
                EmptyStateView("See what is taking up space", systemImage: category.icon, description: "Scan first, then review the exact files before removing anything.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan this category", tint: .accentColor)
            } else {
                Spacer()
            }
        }
        .navigationTitle(Text(LocalizedStringKey(category.rawValue)))
        .animation(motionEnabled ? .easeOut(duration: 0.16) : nil, value: showingReceipt)
        .sheet(item: $pendingReview) { selection in
            CleanupReviewSheet(selection: selection, cancel: { pendingReview = nil }, confirm: {
                pendingReview = nil
                appState.cleanReviewed(selection, category: category)
            })
        }
        .task(id: key) {
            guard key == filterKey else { return }
            await browser.update(key, items: result?.items ?? [])
        }
        .onChange(of: category) { _ in
            showingReceipt = false
            filter = CleanupReviewFilter()
            pendingReview = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(LocalizedStringKey(category.description))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let result {
                    Text("\(result.itemCount) items · \(result.formattedSize) found")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button {
                appState.scanSingleCategory(category)
            } label: {
                Label(result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(appState.scanState.isActive)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func filters(_ rows: CategoryFilteredRows?, summary: SelectionSummary) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                TextField("Find a file or path", text: $filter.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter cleanup files")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            HStack(spacing: 12) {
                Picker("Size", selection: $filter.size) {
                    ForEach(CleanupSizeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 180)
                Picker("Modified", selection: $filter.age) {
                    ForEach(CleanupAgeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 210)
                Spacer(minLength: 0)
                Picker("Sort", selection: $filter.order) {
                    ForEach(CleanupSortOrder.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 185)
            }
            .controlSize(.small)
            HStack {
                if let rows {
                    Text("\(rows.items.count) of \(result?.itemCount ?? 0) items shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(summary.canSelectMore ? "Select visible" : "Deselect visible") {
                    guard let rows, rows.key == filterKey else { return }
                    appState.setSelection(summary.canSelectMore, for: rows.items)
                }
                .disabled(rows == nil || (!summary.canSelectMore && !summary.canDeselect) || appState.scanState.isActive)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private struct SelectionSummary {
        var count = 0
        var size: Int64 = 0
        var hidden = 0
        var canSelectMore = false
        var canDeselect = false
    }

    private func selectionSummary(for items: [CleanableItem], visibleIDs: Set<UUID>?) -> SelectionSummary {
        var summary = SelectionSummary()
        let selection = appState.cleanupRowSelection
        for item in items {
            let isVisible = visibleIDs?.contains(item.id) == true
            if selection.isSelected(item) {
                summary.count += 1
                summary.size += item.size
                if isVisible { summary.canDeselect = true }
                else if visibleIDs != nil { summary.hidden += 1 }
            } else if isVisible && !item.selectOnlyByHand && selection.isAvailable(item) {
                summary.canSelectMore = true
            }
        }
        return summary
    }

    private func selectionBar(_ summary: SelectionSummary, rows: CategoryFilteredRows?) -> some View {
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(summary.count) selected · \(ByteCountFormatter.string(fromByteCount: summary.size, countStyle: .file))")
                    .font(.headline.monospacedDigit())
                Text("Cleanup permanently removes files unless marked Move to Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if summary.hidden > 0 {
                    Text("Includes \(summary.hidden) selected items hidden by filters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if summary.count > 0 {
                Button("Clear selection") { appState.deselectAllInCategory(category) }
                    .buttonStyle(.borderless)
                    .disabled(appState.scanState.isActive)
            }
            Button {
                guard let rows, rows.key == filterKey, let result else { return }
                let selected = result.items.filter(appState.cleanupRowSelection.isSelected)
                guard !selected.isEmpty else { return }
                pendingReview = CleanupSelection(items: selected)
            } label: {
                Text("Review removal")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(rows == nil || summary.count == 0 || appState.scanState.isActive)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .animation(motionEnabled ? .easeOut(duration: 0.14) : nil, value: summary.count == 0)
        .overlay(alignment: .top) { Divider() }
    }

}

struct CategoryFilterKey: Equatable {
    let resultID: UUID
    let filter: CleanupReviewFilter
}

struct CategoryFilteredRows {
    let key: CategoryFilterKey
    let items: [CleanableItem]
    let ids: Set<UUID>
}

@MainActor
final class CategoryFilterState: ObservableObject {
    @Published private var snapshot: CategoryFilteredRows?
    private(set) var requested: CategoryFilterKey?
    private let worker = CategoryFilterWorker()

    func rows(for key: CategoryFilterKey?) -> CategoryFilteredRows? {
        guard let snapshot, snapshot.key == key else { return nil }
        return snapshot
    }

    func update(_ key: CategoryFilterKey?, items: [CleanableItem]) async {
        guard !Task.isCancelled else { return }
        requested = key
        guard let key else {
            snapshot = nil
            await worker.clear()
            return
        }
        guard snapshot?.key != key else { return }
        if !key.filter.query.isEmpty {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        guard requested == key, let rows = await worker.resolve(key, items: items),
              !Task.isCancelled, requested == key else { return }
        snapshot = rows
    }
}

private actor CategoryFilterWorker {
    private var resultID: UUID?
    private var order: CleanupSortOrder?
    private var ranked: [CleanableItem] = []

    func clear() {
        resultID = nil
        order = nil
        ranked = []
    }

    func resolve(_ key: CategoryFilterKey, items: [CleanableItem]) -> CategoryFilteredRows? {
        guard !Task.isCancelled else { return nil }
        if resultID != key.resultID || order != key.filter.order {
            ranked = key.filter.sorted(items)
            resultID = key.resultID
            order = key.filter.order
        }
        guard !Task.isCancelled else { return nil }
        let matches = key.filter.matching(ranked, isCancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return nil }
        return CategoryFilteredRows(key: key, items: matches, ids: Set(matches.map(\.id)))
    }
}

private struct CleanupFileRow: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

    var body: some View {
        let available = appState.isCleanupItemAvailable(item)
        return HStack(spacing: 10) {
            Toggle("Select \(item.name)", isOn: appState.itemBinding(for: item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select \(item.name)")
                .disabled(!available)
            Image(systemName: available ? (item.isActionItem ? "terminal" : "doc") : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(width: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.isSelected && available {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Personal data or an optional cleanup action. Left unselected by default.")
                            .accessibilityLabel("Personal data or an optional cleanup action. Left unselected by default.")
                    }
                }
                Text(item.isActionItem ? String(localized: "Managed cleanup action") : (item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                if !available {
                    Text("Changed since review. Scan again to review this item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let date = item.lastModified {
                Text(date.formatted(date: .numeric, time: .omitted))
                    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    .help(date.formatted(date: .complete, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
            Text(item.formattedSize)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 85, alignment: .trailing)
            if !item.isActionItem {
                Button { reveal() } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(item.name) in Finder")
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if !item.isActionItem {
                Button("Reveal in Finder") { reveal() }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
                Divider()
                Button("Always exclude from cleanup") { appState.excludeFromCleanup(item) }
                    .disabled(appState.scanState.isActive)
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}
