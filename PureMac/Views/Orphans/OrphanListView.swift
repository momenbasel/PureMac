import SwiftUI

struct OrphanListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedOrphans: Set<URL> = []
    @State private var didScan = false
    /// Orphan sizes computed off the main thread. Orphans are exactly the large
    /// leftovers (multi-GB Caches/Containers/Application Support), and their
    /// size is a recursive directory walk — calling it from `body` would re-walk
    /// every realized row on each selection toggle and beachball the UI. We walk
    /// once off-main per result set and rows read the cached value.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

    var body: some View {
        VStack(spacing: 0) {
            if appState.isSearchingOrphans {
                ProgressView("Scanning for orphaned files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanedFiles.isEmpty {
                if didScan {
                    EmptyStateView("No Orphaned Files", systemImage: "checkmark.circle",
                                   description: "No leftover files from uninstalled apps were found.",
                                   action: scan, actionLabel: "Scan for Orphans", tint: Tint.teal)
                } else {
                    EmptyStateView("Leftovers", systemImage: "folder.badge.questionmark",
                                   description: "Find leftovers from deleted apps",
                                   action: scan, actionLabel: "Scan for Orphans", tint: Tint.accent)
                }
            } else {
                HStack {
                    Text("Leftovers").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(appState.orphanedFiles.count) files")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                List {
                    ForEach(appState.orphanedFiles, id: \.self) { fileURL in
                        FileRow(fileURL: fileURL, isSelected: orphanBinding(for: fileURL), fileSize: sizeCache[fileURL],
                                onRemove: { appState.reviewSelectedLeftovers([fileURL]) },
                                onReveal: { revealInFinder(fileURL) })
                            .contextMenu {
                                Button("Reveal in Finder") { revealInFinder(fileURL) }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fileURL.path, forType: .string)
                                }
                                Divider()
                                Button("Always Ignore") { ignoreOrphans([fileURL]) }
                                Button("Review this file") { appState.reviewSelectedLeftovers([fileURL]) }
                            }
                            .transition(motionEnabled ? .opacity.combined(with: .offset(y: 4)) : .identity)
                    }
                }
                footer
            }
        }
        .navigationTitle("Leftovers")
        .task(id: appState.orphanedFiles) {
            let urls = appState.orphanedFiles
            let task = Task.detached(priority: .utility) { () -> [URL: Int64] in
                var sizes: [URL: Int64] = [:]
                for url in urls {
                    guard !Task.isCancelled else { break }
                    sizes[url] = FileSizeCalculator.size(of: url)
                }
                return sizes
            }
            let sizes = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled else { return }
            sizeCache = sizes
        }
        .toolbar {
            ToolbarItem {
                Button(action: scan) { Label("Scan for Orphans", systemImage: "arrow.clockwise") }
                    .disabled(appState.isSearchingOrphans || !appState.canBeginAppRemoval)
            }
        }
        .onAppear {
            if !appState.orphanedFiles.isEmpty || appState.isSearchingOrphans { didScan = true }
        }
        .onChange(of: appState.isSearchingOrphans) { searching in
            if searching { didScan = true }
        }
        .onChange(of: appState.orphanedFiles) { remaining in
            if !remaining.isEmpty { didScan = true }
            selectedOrphans.formIntersection(remaining)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(selectedOrphans.count) of \(appState.orphanedFiles.count) selected")
                    .font(.subheadline).monospacedDigit()
                Spacer()
                if !selectedOrphans.isEmpty && selectedOrphans.allSatisfy({ sizeCache[$0] != nil }) {
                    Text(ByteCountFormatter.string(fromByteCount: selectedOrphans.reduce(Int64(0)) { $0 + (sizeCache[$1] ?? 0) }, countStyle: .file))
                        .font(.subheadline.monospacedDigit())
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { selectionButtons; Spacer(); reviewButton }
                VStack(alignment: .leading) { HStack { selectionButtons }; reviewButton }
            }
        }
        .disabled(!appState.canBeginAppRemoval)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var selectionButtons: some View {
        let allSelected = selectedOrphans.count == appState.orphanedFiles.count
        Button(allSelected ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")) {
            selectedOrphans = allSelected ? [] : Set(appState.orphanedFiles)
        }
        .buttonStyle(.borderless)
        Button(ignoreSelectedLabel) { ignoreOrphans(Array(selectedOrphans)) }
            .disabled(selectedOrphans.isEmpty)
            .buttonStyle(.borderless)
    }

    private var reviewButton: some View {
        Button {
            appState.reviewSelectedLeftovers(selectedOrphans)
        } label: {
            Text("Review Selected Leftovers")
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedOrphans.isEmpty)
    }

    private func scan() {
        guard !appState.isSearchingOrphans, appState.canBeginAppRemoval else { return }
        didScan = true
        appState.findOrphans()
    }

    private var ignoreSelectedLabel: String {
        String(format: String(localized: "Ignore Selected (%lld)"), Int64(selectedOrphans.count))
    }

    /// Persist the given URLs to the ignore list (so future scans skip them)
    /// and drop them from the local selection.
    private func ignoreOrphans(_ urls: [URL]) {
        appState.ignoreOrphans(urls)
        selectedOrphans.subtract(urls)
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

    private func revealInFinder(_ url: URL) {
        // activateFileViewerSelecting handles sandbox-bookmarked paths and
        // missing files better than selectFile(_:inFileViewerRootedAtPath:),
        // which silently no-ops when the path is unreachable from Finder's
        // current scope. If the target itself was removed since the scan,
        // fall back to opening the enclosing directory so the user lands
        // somewhere useful instead of nothing happening.
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
        }
    }


}
