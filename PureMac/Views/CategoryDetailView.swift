import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: CleaningCategory

    @State private var filter = CleanupReviewFilter()
    @State private var showConfirmation = false
    @State private var pendingItems: [CleanableItem] = []

    private var result: CategoryResult? { appState.categoryResults[category] }
    private var visibleItems: [CleanableItem] { filter.apply(to: result?.items ?? []) }
    private var selectedItems: [CleanableItem] { (result?.items ?? []).filter(appState.isItemSelected) }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .scanning = appState.scanState {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(appState.currentScanCategory)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop scan") { appState.cancelScan() }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
            if let result, !result.items.isEmpty {
                filters
                Divider()
                if visibleItems.isEmpty {
                    EmptyStateView("No matching files", systemImage: "line.3.horizontal.decrease.circle", description: "Try another name, size, or date range.", action: { filter = CleanupReviewFilter() }, actionLabel: "Clear filters", tint: Tint.teal)
                } else {
                    List(visibleItems) { item in
                        CleanupFileRow(item: item)
                            .listRowSeparator(.visible)
                    }
                    .listStyle(.inset)
                    .disabled(appState.scanState.isActive)
                }
                selectionBar
            } else if result != nil {
                EmptyStateView("No files found", systemImage: "checkmark.circle", description: appState.hasFullDiskAccess ? "There are no cleanup items in this category." : "Some protected locations are unavailable. Full Disk Access allows a more complete scan.", tint: Tint.teal)
            } else if !appState.scanState.isActive {
                EmptyStateView("See what is taking up space", systemImage: category.icon, description: "Scan first, then review the exact files before removing anything.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan this category", tint: Tint.teal)
            } else {
                Spacer()
            }
        }
        .navigationTitle(Text(LocalizedStringKey(category.rawValue)))
        .confirmationDialog("Remove selected files?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Permanently remove \(pendingItems.count) items", role: .destructive) {
                appState.cleanCategory(category, itemIDs: Set(pendingItems.map(\.id)))
                pendingItems = []
            }
            Button("Cancel", role: .cancel) { pendingItems = [] }
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: category) { _ in
            filter = CleanupReviewFilter()
            pendingItems = []
            showConfirmation = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(systemName: category.icon, tint: Tint.teal, size: 48, corner: 12)
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.system(size: 26, weight: .semibold))
                Text(LocalizedStringKey(category.description))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let result {
                    Text("\(result.itemCount) items · \(result.formattedSize) found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 16)
            Button {
                appState.scanSingleCategory(category)
            } label: {
                Label(result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(appState.scanState.isActive)
        }
        .padding(28)
    }

    private var filters: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file or path", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter cleanup files")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Picker("Size", selection: $filter.size) {
                    ForEach(CleanupSizeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 180)
                Picker("Modified", selection: $filter.age) {
                    ForEach(CleanupAgeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 210)
                Spacer(minLength: 0)
                Picker("Sort", selection: $filter.order) {
                    ForEach(CleanupSortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 185)
            }
            .controlSize(.small)
            HStack {
                Text("\(visibleItems.count) of \(result?.itemCount ?? 0) items shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(visibleItems.allSatisfy(appState.isItemSelected) ? "Deselect visible" : "Select visible") {
                    appState.setSelection(!visibleItems.allSatisfy(appState.isItemSelected), for: visibleItems)
                }
                .disabled(visibleItems.isEmpty || appState.scanState.isActive)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var selectionBar: some View {
        let visibleIDs = Set(visibleItems.map(\.id))
        let hiddenCount = selectedItems.filter { !visibleIDs.contains($0.id) }.count
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectedItems.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if hiddenCount > 0 {
                    Text("Includes \(hiddenCount) selected items hidden by filters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Selected cleanup items are permanently removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !selectedItems.isEmpty {
                Button("Clear selection") { appState.deselectAllInCategory(category) }
                    .buttonStyle(.borderless)
                    .disabled(appState.scanState.isActive)
            }
            Button {
                pendingItems = selectedItems
                showConfirmation = true
            } label: {
                Label("Review removal", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.teal)
            .controlSize(.large)
            .disabled(selectedItems.isEmpty || appState.scanState.isActive)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var confirmationMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: pendingItems.reduce(0) { $0 + $1.size }, countStyle: .file)
        let names = pendingItems.prefix(5).map(\.name).joined(separator: "\n")
        let more = pendingItems.count > 5
            ? "\n" + String(format: String(localized: "And %lld more."), Int64(pendingItems.count - 5))
            : ""
        return String(
            format: String(localized: "%@ selected. This permanently removes the selected files or runs the listed cleanup actions. It cannot be undone.\n\n%@%@"),
            size,
            names,
            more
        )
    }
}

private struct CleanupFileRow: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(item.name)", isOn: appState.itemBinding(for: item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(Tint.teal)
                .accessibilityLabel("Select \(item.name)")
            Image(systemName: item.isActionItem ? "gearshape.2" : "doc")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isActionItem ? String(localized: "Managed cleanup action") : (item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
            }
            Spacer(minLength: 12)
            if !item.isSelected {
                Text("Review")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .help("Personal data or an optional cleanup action. Left unselected by default.")
            }
            if let date = item.lastModified {
                Text(date, style: .date)
                    .font(.system(size: 11))
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
        .padding(.vertical, 9)
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
