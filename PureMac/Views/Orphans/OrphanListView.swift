import SwiftUI

struct OrphanListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedOrphans: Set<URL> = []
    @State private var isRemoving = false
    @State private var removalErrorMessage: String?
    /// Orphan sizes computed off the main thread. Orphans are exactly the large
    /// leftovers (multi-GB Caches/Containers/Application Support), and their
    /// size is a recursive directory walk — calling it from `body` would re-walk
    /// every realized row on each selection toggle and beachball the UI. We walk
    /// once off-main per result set and rows read the cached value.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if appState.isSearchingOrphans {
                VStack(spacing: 16) {
                    ProgressView(LocalizedStringKey("Scanning for orphaned files..."))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanedFiles.isEmpty {
                EmptyStateView("No Orphaned Files", systemImage: "checkmark.circle", description: "No leftover files from uninstalled apps were found.", action: { appState.findOrphans() }, actionLabel: "Scan for Orphans", tint: Tint.green)
            } else {
                List {
                    // No .staggered(): List is lazy, so a delayed-reveal would
                    // blank each row as it scrolls in. The removal transition
                    // below still gives the sweep-out on delete.
                    ForEach(Array(appState.orphanedFiles.enumerated()), id: \.element) { _, fileURL in
                        OrphanRowView(
                            fileURL: fileURL,
                            isSelected: orphanBinding(for: fileURL),
                            fileSize: sizeCache[fileURL],
                            onReveal: { revealInFinder(fileURL) },
                            onCopyPath: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fileURL.path, forType: .string)
                            },
                            onIgnore: { ignoreOrphans([fileURL]) },
                            onTrash: { Task { await removeSingleOrphan(fileURL) } }
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                }
            }
        }
        .navigationTitle(orphanedFilesTitle)
        .task(id: appState.orphanedFiles) {
            // Recompute off the main thread whenever the orphan set changes
            // (new scan, removals). FileSizeCalculator is a plain static helper
            // with no main-actor isolation, so it runs safely on a detached
            // background task; the result is applied back on the main actor.
            let urls = appState.orphanedFiles
            let sizes = await Task.detached(priority: .utility) { () -> [URL: Int64] in
                var out: [URL: Int64] = [:]
                for url in urls {
                    out[url] = FileSizeCalculator.size(of: url) ?? 0
                }
                return out
            }.value
            sizeCache = sizes
        }
        .toolbar {
            ToolbarItemGroup {
                if !appState.orphanedFiles.isEmpty {
                    Button(LocalizedStringKey(selectedOrphans.count == appState.orphanedFiles.count ? "Deselect All" : "Select All")) {
                        if selectedOrphans.count == appState.orphanedFiles.count {
                            selectedOrphans.removeAll()
                        } else {
                            selectedOrphans = Set(appState.orphanedFiles)
                        }
                    }
                }

                Button("Scan for Orphans") {
                    appState.findOrphans()
                }

                if !selectedOrphans.isEmpty {
                    Button(ignoreSelectedLabel) {
                        ignoreOrphans(Array(selectedOrphans))
                    }
                    .disabled(isRemoving)

                    Button(removeSelectedLabel, role: .destructive) {
                        Task {
                            await removeSelectedOrphans()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isRemoving)
                }
            }
        }
        .alert("Some files could not be removed", isPresented: Binding(
            get: { removalErrorMessage != nil },
            set: { if !$0 { removalErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalErrorMessage ?? "")
        }
    }

    private var orphanedFilesTitle: String {
        String(format: String(localized: "Orphaned Files (%lld)"), Int64(appState.orphanedFiles.count))
    }

    private var removeSelectedLabel: String {
        String(format: String(localized: "Remove Selected (%lld)"), Int64(selectedOrphans.count))
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

    private func removeSelectedOrphans() async {
        isRemoving = true
        defer { isRemoving = false }

        let urlsToRemove = selectedOrphans
        var failedPaths: [String] = []
        var removedURLs: Set<URL> = []
        var needsAdminURLs: [URL] = []

        for url in urlsToRemove {
            guard OrphanSafetyPolicy.isSafeCandidate(url) else {
                failedPaths.append("\(url.path) (blocked by safety policy)")
                continue
            }

            switch removeOrphan(url) {
            case .removed:
                removedURLs.insert(url)
            case .needsAdmin:
                needsAdminURLs.append(url)
            case .failed:
                failedPaths.append(url.path)
            }
        }

        if !needsAdminURLs.isEmpty {
            if removeWithAdminPrivileges(needsAdminURLs) {
                for url in needsAdminURLs {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        removedURLs.insert(url)
                    } else {
                        failedPaths.append(url.path)
                    }
                }
            } else {
                failedPaths.append(contentsOf: needsAdminURLs.map(\.path))
            }
        }

        // Sweep removed rows out (per-row transitions are attached in the
        // List above); plain assignment under Reduce Motion.
        if reduceMotion {
            appState.orphanedFiles.removeAll { removedURLs.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appState.orphanedFiles.removeAll { removedURLs.contains($0) }
            }
        }
        selectedOrphans.subtract(removedURLs)

        if !failedPaths.isEmpty {
            let preview = failedPaths.prefix(3).joined(separator: "\n")
            let suffix = failedPaths.count > 3 ? "\n…" : ""
            removalErrorMessage = "\(failedPaths.count) item(s) failed to delete.\n\n\(preview)\(suffix)"
        }
    }

    private enum OrphanRemoveOutcome {
        case removed
        case needsAdmin
        case failed
    }

    private func removeOrphan(_ url: URL) -> OrphanRemoveOutcome {
        do {
            try FileManager.default.removeItem(at: url)
            return .removed
        } catch {
            let nsError = error as NSError
            let permissionDeniedCodes = [
                NSFileReadNoPermissionError,
                NSFileWriteNoPermissionError,
                NSFileWriteUnknownError,
                257,
                513,
            ]

            guard permissionDeniedCodes.contains(nsError.code) else {
                return .failed
            }

            return .needsAdmin
        }
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

    private func removeSingleOrphan(_ url: URL) async {
        let previous = selectedOrphans
        selectedOrphans = [url]
        await removeSelectedOrphans()
        selectedOrphans = previous.subtracting([url])
    }

    private func removeWithAdminPrivileges(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }
        guard urls.allSatisfy({ OrphanSafetyPolicy.isSafeCandidate($0) }) else { return false }

        // Quote path for a POSIX shell command.
        let quotedPaths = urls.map { url in
            "'\(url.path.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
        }
        let shellCommand = "rm -rf -- \(quotedPaths.joined(separator: " "))"
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Row

/// Orphan row extracted to its own struct so hover highlight and the springy
/// checkbox are per-row state.
private struct OrphanRowView: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onIgnore: () -> Void
    let onTrash: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

                // Hover-revealed Finder shortcut; stays in the layout so the
                // trailing size never shifts sideways.
                Button {
                    onReveal()
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

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: Tint.pink))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { onReveal() }
            Button("Copy Path") { onCopyPath() }
            Divider()
            Button("Always Ignore") { onIgnore() }
            Button("Move to Trash", role: .destructive) { onTrash() }
        }
    }
}
