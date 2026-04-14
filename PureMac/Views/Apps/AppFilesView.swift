import SwiftUI

struct AppFilesView: View {
    @EnvironmentObject var appState: AppState
    let app: AppInfoPlaceholder

    var body: some View {
        VStack(spacing: 0) {
            // App header
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.title2)
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !appState.discoveredFiles.isEmpty {
                    let totalSize = appState.discoveredFiles.reduce(Int64(0)) { total, url in
                        total + (fileSize(url) ?? 0)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            if appState.discoveredFiles.isEmpty {
                EmptyStateView("No Related Files Found", systemImage: "magnifyingglass", description: "No additional files were found for this application.")
            } else {
                List(appState.discoveredFiles, id: \.self) { fileURL in
                    Toggle(isOn: fileSelectionBinding(for: fileURL)) {
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
        .toolbar {
            ToolbarItemGroup {
                if !appState.discoveredFiles.isEmpty {
                    Button("Select All") {
                        appState.selectedFiles = Set(appState.discoveredFiles)
                    }
                    Button("Deselect All") {
                        appState.selectedFiles.removeAll()
                    }

                    if !appState.selectedFiles.isEmpty {
                        Button("Remove Selected", role: .destructive) {
                            // Will be connected to cleaning engine
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }
        }
    }

    private func fileSelectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { appState.selectedFiles.contains(url) },
            set: { selected in
                if selected {
                    appState.selectedFiles.insert(url)
                } else {
                    appState.selectedFiles.remove(url)
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
