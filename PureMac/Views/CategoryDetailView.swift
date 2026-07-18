import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    let category: CleaningCategory

    @State private var sortDescending: Bool = true
    @State private var searchText = ""
    @State private var showConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var result: CategoryResult? {
        appState.categoryResults[category]
    }

    var body: some View {
        VStack(spacing: 0) {
            heroCard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Group {
                if let result = result {
                    if result.items.isEmpty {
                        EmptyStateView("All Clean", systemImage: "checkmark.circle", description: "No junk files found in this category.", tint: Tint.green)
                    } else {
                        VStack(spacing: 0) {
                            selectionStrip(result)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 10)
                            fileList(result)
                        }
                    }
                } else {
                    EmptyStateView("Not Scanned", systemImage: category.icon, description: "Run a scan to analyze this category.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan Now", tint: category.color)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter files")
        .navigationTitle(Text(LocalizedStringKey(category.rawValue)))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(appState.scanState.isActive)
            }

            ToolbarItem(placement: .automatic) {
                if let result = result, !result.items.isEmpty {
                    Button(action: { sortDescending.toggle() }) {
                        Label {
                            Text(LocalizedStringKey(sortDescending ? "Largest First" : "Smallest First"))
                        } icon: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    .help(LocalizedStringKey(sortDescending ? "Sorted: Largest First" : "Sorted: Smallest First"))
                }
            }
        }
        .confirmationDialog(cleanConfirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Clean", role: .destructive) {
                appState.cleanCategory(category)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected files. This cannot be undone.")
        }
    }

    private func cleanItemsLabel(count: Int) -> String {
        String(format: String(localized: "Clean %lld items"), Int64(count))
    }

    private var cleanConfirmationTitle: String {
        String(
            format: String(localized: "Clean %@?"),
            ByteCountFormatter.string(fromByteCount: appState.selectedSizeInCategory(category), countStyle: .file)
        )
    }

    // MARK: - Hero

    private var heroCard: some View {
        let totalSize = result?.totalSize ?? 0
        let itemCount = result?.itemCount ?? 0
        let isScanning = appState.scanState.isActive

        return CardSurface(padding: 20, tint: category.color) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(systemName: category.icon, tint: category.color, size: 60, corner: 16, vivid: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(category.rawValue))
                        .font(.system(size: 22, weight: .bold))
                    Text(LocalizedStringKey(category.description))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    if itemCount > 0 {
                        Text(itemsAndSizeText(itemCount: itemCount, totalSize: totalSize))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .foregroundStyle(category.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(category.color.opacity(0.12)))
                            .padding(.top, 4)
                            .animation(reduceMotion ? nil : MotionTokens.gentle, value: totalSize)
                    }
                }

                Spacer()

                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label {
                        Text(scanButtonLabel(isScanning: isScanning, hasResult: result != nil))
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(category.color)
                .controlSize(.large)
                .disabled(isScanning)
            }
        }
    }

    /// Persistent action strip above the file list: tri-state select-all,
    /// live selection count, selected size, and the Clean CTA. Previously
    /// these lived only in the toolbar, one extra glance away from the rows
    /// they act on.
    private func selectionStrip(_ result: CategoryResult) -> some View {
        let selectedCount = appState.selectedCountInCategory(category)
        let totalCount = result.itemCount
        let selectedSize = appState.selectedSizeInCategory(category)

        return CardSurface(padding: 10, elevation: .flat) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { selectedCount == totalCount && totalCount > 0 },
                    set: { newValue in
                        if newValue {
                            appState.selectAllInCategory(category)
                        } else {
                            appState.deselectAllInCategory(category)
                        }
                    }
                )) {
                    Text(
                        String(
                            format: String(localized: "%lld of %lld selected"),
                            Int64(selectedCount),
                            Int64(totalCount)
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                }
                .toggleStyle(AnimatedCheckboxStyle(tint: category.color))
                .animation(reduceMotion ? nil : MotionTokens.gentle, value: selectedCount)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if selectedSize > 0 {
                    Button {
                        showConfirmation = true
                    } label: {
                        Label {
                            Text(cleanItemsLabel(count: selectedCount))
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: selectedSize > 0)
        }
    }

    private func itemsAndSizeText(itemCount: Int, totalSize: Int64) -> String {
        String(
            format: String(localized: "%lld items · %@"),
            Int64(itemCount),
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        )
    }

    private func scanButtonLabel(isScanning: Bool, hasResult: Bool) -> LocalizedStringKey {
        if isScanning { return "Scanning…" }
        if hasResult { return "Rescan" }
        return "Scan"
    }

    // MARK: - File List

    private func fileList(_ result: CategoryResult) -> some View {
        let items = sortedItems(result.items).filter { item in
            searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText) || item.path.localizedCaseInsensitiveContains(searchText)
        }
        return List {
            // No .staggered() here: List is lazy, so a delayed-reveal
            // modifier would blank each row for ~0.45s as it scrolls into
            // view on large scans. The row hover/selection polish carries
            // the motion; the list-level sort/filter animation handles
            // reorders.
            ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                FileRowView(item: item)
            }
        }
        // CleanableItem ids are stable, so SwiftUI move-animates re-sorts and
        // fades filtered rows instead of snapping.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: sortDescending)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: searchText)
    }

    private func sortedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        items.sorted { sortDescending ? $0.size > $1.size : $0.size < $1.size }
    }
}

// MARK: - File Row View

private struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool {
        appState.isItemSelected(item)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isSelected },
            set: { _ in appState.toggleItem(item) }
        )) {
            HStack {
                Image(systemName: fileIcon)
                    .foregroundStyle(item.category.color.opacity(0.85))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !item.path.isEmpty {
                        Text(item.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                // Hover-revealed Finder shortcut; stays in the layout so the
                // trailing size never shifts sideways.
                if !item.path.isEmpty {
                    Button {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (hovering ? 1 : 0.8))
                    .allowsHitTesting(hovering)
                }

                if let date = item.lastModified {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.formattedSize)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: item.category.color))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    hovering
                        ? Color.primary.opacity(0.06)
                        : (isSelected ? item.category.color.opacity(0.04) : .clear)
                )
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .onHover { hovering = $0 }
        .contextMenu {
            if !item.path.isEmpty {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            }
        }
    }

    private var fileIcon: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "log", "txt": return "doc.text"
        case "zip", "gz", "tar": return "doc.zipper"
        case "dmg", "iso": return "opticaldisc"
        case "app": return "app"
        case "pkg": return "shippingbox"
        default:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                return "folder"
            }
            return "doc"
        }
    }
}
