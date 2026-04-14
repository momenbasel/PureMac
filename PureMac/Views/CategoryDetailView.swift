import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    let category: CleaningCategory

    @State private var sortDescending: Bool = true

    private var result: CategoryResult? {
        appState.categoryResults[category]
    }

    var body: some View {
        Group {
            if let result = result {
                if result.items.isEmpty {
                    EmptyStateView("All Clean", systemImage: "checkmark.circle", description: "No junk files found in this category.")
                } else {
                    fileList(result)
                }
            } else {
                EmptyStateView("Not Scanned", systemImage: category.icon, description: "Run a scan to analyze this category.")
            }
        }
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItemGroup {
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

                if result == nil || !appState.scanState.isActive {
                    Button {
                        appState.scanSingleCategory(category)
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                }

                if let _ = result, !appState.scanState.isActive {
                    let selectedSize = appState.selectedSizeInCategory(category)
                    let selectedCount = appState.selectedCountInCategory(category)
                    if selectedSize > 0 {
                        Button {
                            appState.cleanCategory(category)
                        } label: {
                            Label(
                                "Clean \(selectedCount) items (\(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)))",
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - File List

    private func fileList(_ result: CategoryResult) -> some View {
        List {
            Section {
                ForEach(sortedItems(result.items)) { item in
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
