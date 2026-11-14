import AppKit
import SwiftUI

struct DevProjectsView: View {
    private enum ScreenState: Equatable {
        case idle
        case scanning
        case finished
    }

    private struct OutcomeMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    /// Artifacts newer than this stay unchecked so active projects keep their dependencies.
    private static let olderThanDays = 7

    @State private var state: ScreenState = .idle
    @State private var result: DevProjectScanResult?
    @State private var selectedFolder: URL?
    @State private var selectedIDs: Set<URL> = []
    @State private var scanTask: Task<Void, Never>?
    @State private var removeTask: Task<Void, Never>?
    @State private var isRemoving = false
    @State private var showsConfirmation = false
    @State private var outcome: OutcomeMessage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                header
                content
                if let result, !result.items.isEmpty {
                    selectionBar
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            "Delete selected items permanently?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedIDs.count) items totaling \(format(selectedSize)) will be permanently deleted. Worktrees are removed with git, which refuses anything with uncommitted changes. This cannot be undone.")
        }
        .alert(item: $outcome) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
        }
        .onDisappear {
            scanTask?.cancel()
            removeTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        CardSurface(padding: 18, elevation: .flat, tint: Tint.accent) {
            HStack(spacing: 14) {
                IconTile(systemName: "hammer", tint: Tint.accent, size: 42, corner: 11)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projects & Worktrees")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(selectedFolder?.path ?? String(localized: "Remove build artifacts and git worktrees from a folder"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                if state == .scanning {
                    Button("Cancel", role: .cancel) { scanTask?.cancel() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button { chooseFolder() } label: {
                        Label(result == nil ? "Choose Folder" : "Scan Another Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.accent)
                    .disabled(isRemoving)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .finished:
            if let result, result.items.isEmpty {
                emptyState(result)
            } else if let result {
                resultList(result)
            } else {
                idleState
            }
        }
    }

    private var idleState: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                Image(systemName: "shippingbox")
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tint.accent)
                Text("Reclaim space from developer projects")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose a folder such as ~/Developer. PureMac finds node_modules, .turbo, build output and git worktrees, including .claude/worktrees, .orc and Supacode. Only older artifacts and clean, pushed worktrees are pre-selected. Nothing is deleted until you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button { chooseFolder() } label: {
                    Label("Choose a Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
                .controlSize(.large)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        CardSurface(padding: 28, elevation: .flat, tint: Tint.accent) {
            VStack(spacing: 16) {
                Spacer()
                ProgressView().controlSize(.large).tint(Tint.accent)
                Text("Looking through projects")
                    .font(.system(size: 18, weight: .semibold))
                Text("Checking artifacts and git worktrees. Large folders can take a few minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(_ result: DevProjectScanResult) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.green) {
            VStack(spacing: 14) {
                Spacer()
                IconTile(systemName: "checkmark.seal.fill", tint: Tint.green, size: 58, corner: 16)
                Text("Nothing to clean up")
                    .font(.system(size: 19, weight: .semibold))
                Text("No build artifacts or git worktrees were found in \(result.folder.lastPathComponent).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Scan Again") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultList(_ result: DevProjectScanResult) -> some View {
        let groups = Dictionary(grouping: result.items, by: \.project)
            .map { (project: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { lhs, rhs in lhs.items.reduce(0) { $0 + $1.size } > rhs.items.reduce(0) { $0 + $1.size } }
        return ScrollView {
            LazyVStack(spacing: 14) {
                summaryCard(result)
                ForEach(groups, id: \.project) { group in
                    groupCard(project: group.project, items: group.items)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func summaryCard(_ result: DevProjectScanResult) -> some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 18) {
                metric(value: result.items.count.formatted(), label: "Items found", icon: "square.stack.3d.up", tint: Tint.accent)
                metric(value: format(result.totalSize), label: "Total size", icon: "internaldrive", tint: Tint.green)
                Spacer(minLength: 10)
                Button("Rescan") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                    .disabled(isRemoving)
            }
        }
    }

    private func metric(value: String, label: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            IconTile(systemName: icon, tint: tint, size: 30, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func groupCard(project: String, items: [DevProjectItem]) -> some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 0) {
                HStack {
                    Text(project).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(format(items.reduce(0) { $0 + $1.size }))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                ForEach(items) { item in
                    Divider()
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: DevProjectItem) -> some View {
        let isOn = Binding<Bool>(
            get: { selectedIDs.contains(item.id) },
            set: { on in
                if on { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
            }
        )
        return HStack(spacing: 10) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isRemoving)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayPath(item.url))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusChip(label: kindLabel(item.kind), tint: item.kind == .artifact ? Tint.blue : Tint.purple)
                    if let note = item.note {
                        StatusChip(label: String(localized: String.LocalizationValue(note)), tint: Tint.orange)
                    }
                }
                if let modified = item.modified {
                    Text(modified.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(format(item.size))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(Text("Reveal in Finder"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Always Exclude") { exclude(item) }
        }
    }

    private var selectionBar: some View {
        CardSurface(padding: 14, elevation: .raised, tint: selectedIDs.isEmpty ? nil : Tint.red) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedIDs.isEmpty ? "Nothing selected" : "\(selectedIDs.count) selected")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(selectedIDs.isEmpty
                         ? "Select the items you want to review"
                         : "\(format(selectedSize)) will be permanently deleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select Recommended") { selectRecommended() }
                    .buttonStyle(.borderless)
                    .disabled(isRemoving)
                if !selectedIDs.isEmpty {
                    Button("Clear Selection") { selectedIDs.removeAll() }
                        .buttonStyle(.borderless)
                        .disabled(isRemoving)
                }
                Button { showsConfirmation = true } label: {
                    if isRemoving {
                        ProgressView().controlSize(.small).frame(minWidth: 110)
                    } else {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.red)
                .disabled(selectedIDs.isEmpty || isRemoving || state == .scanning)
                .accessibilityHint("Shows a confirmation before deleting the selected items")
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        guard !isRemoving else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder of projects")
        panel.prompt = String(localized: "Scan Folder")
        panel.message = String(localized: "PureMac reads the selected folder and does not change anything during a scan.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        if panel.runModal() == .OK, let folder = panel.url {
            startScan(folder)
        }
    }

    private func startScan(_ folder: URL) {
        guard !isRemoving else { return }
        guard DevProjectCleaner.isValidScanRoot(folder) else {
            outcome = OutcomeMessage(
                title: String(localized: "Choose a project folder"),
                detail: String(localized: "Your home folder, Library and system locations cannot be scanned. Pick a folder like ~/Developer instead.")
            )
            return
        }
        scanTask?.cancel()
        selectedFolder = folder
        selectedIDs = []
        result = nil
        state = .scanning
        let excluded = CleanupExclusions.paths()
        scanTask = Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                DevProjectCleaner.scan(
                    folder: folder,
                    extraRoots: DevProjectCleaner.supacodeRoots,
                    olderThanDays: Self.olderThanDays,
                    excludedPaths: excluded
                )
            }.value
            guard !Task.isCancelled else {
                state = result == nil ? .idle : .finished
                return
            }
            result = scanned
            selectedIDs = Set(scanned.items.filter(\.preselected).map(\.id))
            state = .finished
        }
    }

    private func selectRecommended() {
        guard let result else { return }
        selectedIDs = Set(result.items.filter(\.preselected).map(\.id))
    }

    private func removeSelected() {
        guard let result, !isRemoving else { return }
        let items = result.items.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        isRemoving = true
        let excluded = CleanupExclusions.paths()
        removeTask = Task {
            let out = await Task.detached(priority: .userInitiated) {
                DevProjectCleaner.remove(items, excludedPaths: excluded)
            }.value
            isRemoving = false
            var detail = String(localized: "Removed \(out.removed) items, freeing \(format(out.freedBytes)).")
            let problems = out.skipped.count + out.failed.count
            if problems > 0 {
                let reasons = (out.skipped.map { "\(displayPath(URL(fileURLWithPath: $0.path))): \($0.reason)" }
                    + out.failed.map { "\(displayPath(URL(fileURLWithPath: $0.path))): \($0.error)" }).prefix(5)
                detail += "\n\n" + String(localized: "\(problems) could not be removed and were kept:") + "\n" + reasons.joined(separator: "\n")
            }
            outcome = OutcomeMessage(title: String(localized: "Cleanup finished"), detail: detail)
            if let folder = selectedFolder { startScan(folder) }
        }
    }

    private func exclude(_ item: DevProjectItem) {
        CleanupExclusions.add(item.url.path)
        guard let current = result else { return }
        let remaining = current.items.filter { $0.id != item.id }
        result = DevProjectScanResult(folder: current.folder, items: remaining)
        selectedIDs.remove(item.id)
    }

    // MARK: - Helpers

    private var selectedSize: Int64 {
        result?.items.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size } ?? 0
    }

    private func kindLabel(_ kind: DevProjectItem.Kind) -> String {
        switch kind {
        case .artifact: return String(localized: "Artifact")
        case .worktree: return String(localized: "Worktree")
        case .orphanedWorktree: return String(localized: "Orphaned")
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
