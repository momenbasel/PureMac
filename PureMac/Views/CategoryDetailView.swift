import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    let category: CleaningCategory

    @State private var sortDescending: Bool = true
    @State private var searchText = ""
    @State private var showConfirmation = false

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
                        EmptyStateView("All Clean", systemImage: "checkmark.circle", description: "No junk files found in this category.")
                    } else {
                        fileList(result)
                    }
                } else {
                    EmptyStateView("Not Scanned", systemImage: category.icon, description: "Run a scan to analyze this category.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan Now")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter files")
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(appState.scanState.isActive)
            }

            ToolbarItemGroup(placement: .automatic) {
                if let result = result, !result.items.isEmpty {
                    Button("Select All") {
                        appState.selectAllInCategory(category)
                    }
                    Button("Deselect All") {
                        appState.deselectAllInCategory(category)
                    }
                    Button(action: { sortDescending.toggle() }) {
                        Label(
                            sortDescending ? "Largest First" : "Smallest First",
                            systemImage: "arrow.up.arrow.down"
                        )
                    }
                    .help(sortDescending ? "Sorted: Largest First" : "Sorted: Smallest First")
                }
            }

            ToolbarItem(placement: .automatic) {
                if let _ = result, !appState.scanState.isActive {
                    let selectedSize = appState.selectedSizeInCategory(category)
                    let selectedCount = appState.selectedCountInCategory(category)
                    if selectedSize > 0 {
                        Button {
                            showConfirmation = true
                        } label: {
                            Label(
                                "Clean \(selectedCount) items",
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clean \(ByteCountFormatter.string(fromByteCount: appState.selectedSizeInCategory(category), countStyle: .file))?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Clean", role: .destructive) {
                appState.cleanCategory(category)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected files. This cannot be undone.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        let totalSize = result?.totalSize ?? 0
        let itemCount = result?.itemCount ?? 0
        let isScanning = appState.scanState.isActive

        return CardSurface(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(systemName: category.icon, tint: category.color, size: 56, corner: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text(category.rawValue)
                        .font(.system(size: 22, weight: .bold))
                    Text(category.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if itemCount > 0 {
                        Text("\(itemCount) items · \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(category.color)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label(isScanning ? "Scanning…" : (result == nil ? "Scan" : "Rescan"),
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isScanning)
            }
        }
    }

    // MARK: - File List

    private func fileList(_ result: CategoryResult) -> some View {
        let items = sortedItems(result.items).filter { item in
            searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText) || item.path.localizedCaseInsensitiveContains(searchText)
        }
        return List {
            Section {
                ForEach(items) { item in
                    FileRowView(item: item)
                }
            } header: {
                let selectedCount = appState.selectedCountInCategory(category)
                let totalCount = result.itemCount
                Text("\(selectedCount) of \(totalCount) selected")
            }
        }
    }

    private func sortedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        items.sorted { sortDescending ? $0.size > $1.size : $0.size < $1.size }
    }
}

// MARK: - File Row View

private struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

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
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let date = item.lastModified {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.formattedSize)
                    .font(.callout)
                    .fontWeight(.medium)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
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
