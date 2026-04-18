import SwiftUI

struct AppFilesView: View {
    @EnvironmentObject var appState: AppState
    let app: InstalledApp

    private var totalSelectedSize: Int64 {
        appState.selectedFiles.reduce(Int64(0)) { total, url in
            total + (fileSize(url) ?? 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // App header
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.title3.bold())
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !appState.discoveredFiles.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(fileCountText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file))
                            .font(.callout.bold())
                    }
                }
            }
            .padding()

            Divider()

            // Content
            if appState.isScanningAppFiles {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Scanning for related files...")
                    Text(checkingLocationsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.discoveredFiles.isEmpty {
                EmptyStateView(
                    "No Related Files",
                    systemImage: "checkmark.circle",
                    description: "No additional files found for \(app.appName)."
                )
            } else {
                List(appState.discoveredFiles, id: \.self) { fileURL in
                    FileRow(
                        fileURL: fileURL,
                        isSelected: fileSelectionBinding(for: fileURL),
                        fileSize: fileSize(fileURL),
                        onRemove: { removeSingleFile(fileURL) }
                    )
                }

                // Bottom action bar
                HStack {
                    Button("Select All") {
                        appState.selectedFiles = Set(appState.discoveredFiles)
                    }
                    Button("Deselect All") {
                        appState.selectedFiles.removeAll()
                    }

                    Spacer()

                    if !appState.selectedFiles.isEmpty {
                        Button(uninstallSelectedTitle, role: .destructive) {
                            appState.removeSelectedFiles()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding()
            }
        }
        .alert("Removal Failed", isPresented: Binding(
            get: { appState.removalError != nil },
            set: { if !$0 { appState.removalError = nil } }
        )) {
            Button("Open System Settings") {
                FullDiskAccessManager.shared.openFullDiskAccessSettings()
                appState.removalError = nil
            }
            Button("OK", role: .cancel) {
                appState.removalError = nil
            }
        } message: {
            Text(appState.removalError ?? "")
        }
    }

    private var fileCountText: String {
        String(format: String(localized: "%lld files"), Int64(appState.discoveredFiles.count))
    }

    private var checkingLocationsText: String {
        String(format: String(localized: "Checking %lld locations..."), Int64(appState.currentAppFileSearchLocationCount))
    }

    private var uninstallSelectedTitle: String {
        String(
            format: String(localized: "Uninstall %lld files (%@)"),
            Int64(appState.selectedFiles.count),
            ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
        )
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

    private func removeSingleFile(_ url: URL) {
        appState.selectedFiles = [url]
        appState.removeSelectedFiles()
    }
}

// MARK: - File Row with hover-to-reveal actions

struct FileRow: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var showConfirmation = false

    var body: some View {
        Toggle(isOn: $isSelected) {
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

                if isHovering {
                    Button {
                        NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .transition(.opacity)

                    Button {
                        showConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this file")
                    .transition(.opacity)
                }

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .alert("Remove \(fileURL.lastPathComponent)?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This will permanently delete this file. This action cannot be undone.")
        }
    }
}
