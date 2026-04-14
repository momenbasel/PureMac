import SwiftUI

struct OrphanListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedOrphans: Set<URL> = []

    var body: some View {
        Group {
            if appState.isSearchingOrphans {
                VStack(spacing: 16) {
                    ProgressView("Scanning for orphaned files...")
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanedFiles.isEmpty {
                EmptyStateView("No Orphaned Files", systemImage: "checkmark.circle", description: "No leftover files from uninstalled apps were found.", action: { /* Will be connected to OrphanFinder */ }, actionLabel: "Scan for Orphans")
            } else {
                List(appState.orphanedFiles, id: \.self) { fileURL in
                    Toggle(isOn: orphanBinding(for: fileURL)) {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                                .resizable()
                                .frame(width: 16, height: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileURL.lastPathComponent)
                                    .lineLimit(1)
                                Text(fileURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if let size = fileSize(fileURL) {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
                        }
                    }
                }
            }
        }
        .navigationTitle("Orphaned Files (\(appState.orphanedFiles.count))")
        .toolbar {
            ToolbarItemGroup {
                Button("Scan for Orphans") {
                    // Will be connected to OrphanFinder
                }

                if !selectedOrphans.isEmpty {
                    Button("Remove Selected", role: .destructive) {
                        // Will be connected to cleaning engine
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    private func orphanBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedOrphans.contains(url) },
            set: { selected in
                if selected {
                    selectedOrphans.insert(url)
                } else {
                    selectedOrphans.remove(url)
                }
            }
        )
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}
