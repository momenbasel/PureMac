import AppKit
import SwiftUI

@MainActor
final class DuplicateFinderViewModel: ObservableObject {
    enum ScreenState: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private let finder: DuplicateFinder
    @Published private(set) var state: ScreenState = .idle
    @Published private(set) var result: DuplicateScanResult?
    @Published private(set) var selectedFolder: URL?
    @Published private(set) var progress = DuplicateScanProgress(
        phase: .discovering,
        filesInspected: 0,
        filesToHash: 0,
        filesHashed: 0,
        bytesHashed: 0,
        currentURL: nil
    )
    @Published var selectedIDs: Set<URL> = []
    @Published var expandedGroupIDs: Set<String> = []
    private var scanGeneration = UUID()
    private(set) var scanTask: Task<Void, Never>?
    private(set) var trashTask: Task<Void, Never>?
    @Published private(set) var isMovingToTrash = false
    @Published var actionMessage: DuplicateActionMessage?

    init(finder: DuplicateFinder = DuplicateFinder()) {
        self.finder = finder
    }

    var selectedSize: Int64 {
        guard let result else { return 0 }
        return result.groups
            .flatMap(\.files)
            .filter { selectedIDs.contains($0.url) }
            .reduce(0) { $0 + $1.size }
    }

    func groupCandidatesSelected(_ group: DuplicateGroup) -> Bool {
        group.files.dropFirst().allSatisfy { selectedIDs.contains($0.url) }
    }

    func toggleGroupSelection(_ group: DuplicateGroup) {
        guard !isMovingToTrash, let group = result?.groups.first(where: { $0.id == group.id }) else { return }
        let candidateIDs = Set(group.files.dropFirst().map(\.url))
        if candidateIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(candidateIDs)
        } else {
            selectedIDs.formUnion(candidateIDs)
        }
    }

    func selectAllCopies() {
        guard !isMovingToTrash, let groups = result?.groups else { return }
        selectedIDs = Set(groups.flatMap { $0.files.dropFirst().map(\.url) })
    }

    func keep(_ url: URL, in groupID: String) {
        guard !isMovingToTrash, var updated = result,
              let index = updated.groups.firstIndex(where: { $0.id == groupID }),
              let group = updated.groups[index].keeping(url) else { return }
        selectedIDs.remove(url)
        updated.groups[index] = group
        result = updated
    }

    func cancelScan() {
        guard state == .scanning else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    func leaveReview() {
        if !selectedIDs.isEmpty { selectedIDs.removeAll() }
        trashTask?.cancel()
    }

    func startScan(_ folder: URL) {
        guard !isMovingToTrash else { return }
        scanTask?.cancel()
        actionMessage = nil
        let generation = UUID()
        scanGeneration = generation
        selectedFolder = folder.standardizedFileURL
        selectedIDs.removeAll()
        expandedGroupIDs.removeAll()
        result = nil
        progress = DuplicateScanProgress(
            phase: .discovering,
            filesInspected: 0,
            filesToHash: 0,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: folder
        )
        state = .scanning
        scanTask = Task { @MainActor [self] in
            let usesScopedAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let scanResult = try await finder.scan(folder: folder) { [self] update in
                    await MainActor.run {
                        guard self.scanGeneration == generation else { return }
                        self.progress = update
                    }
                }
                try Task.checkCancellation()
                guard scanGeneration == generation else { return }
                result = scanResult
                expandedGroupIDs = Set(scanResult.groups.prefix(3).map(\.id))
                state = .finished
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                state = .idle
            } catch {
                guard scanGeneration == generation else { return }
                state = .failed(error.localizedDescription)
            }
            if scanGeneration == generation {
                scanTask = nil
            }
        }
    }

    func moveSelectedToTrash() {
        guard !isMovingToTrash, let currentResult = result, !selectedIDs.isEmpty else { return }
        let generation = scanGeneration
        let folder = currentResult.folder
        let selectionSnapshot = selectedIDs
        isMovingToTrash = true
        trashTask = Task { @MainActor [self] in
            let usesScopedAccess = currentResult.folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    currentResult.folder.stopAccessingSecurityScopedResource()
                }
                if scanGeneration == generation {
                    isMovingToTrash = false
                    trashTask = nil
                }
            }
            var movedFiles: [DuplicateFile] = []
            var failures: [String] = []
            for group in currentResult.groups {
                if Task.isCancelled { break }
                let groupSelection = selectionSnapshot.filter { group.contains($0) }
                guard !groupSelection.isEmpty else { continue }
                do {
                    let report = try await finder.moveToTrash(group: group, selectedIDs: groupSelection)
                    movedFiles.append(contentsOf: report.trashedFiles)
                    failures.append(contentsOf: report.failures.map { "\($0.url.lastPathComponent): \($0.message)" })
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            guard scanGeneration == generation,
                  selectedFolder == folder,
                  result?.folder == folder else { return }
            applyTrashResult(movedFiles)
            if Task.isCancelled {
                if !movedFiles.isEmpty {
                    let count = String(localized: "\(movedFiles.count) files")
                    let size = format(movedFiles.reduce(0) { $0 + $1.size })
                    actionMessage = DuplicateActionMessage(
                        title: String(localized: "Moved to Trash"),
                        detail: "\(count) · \(size)\n" + String(localized: "The operation was cancelled.")
                    )
                }
                return
            }
            if failures.isEmpty {
                actionMessage = DuplicateActionMessage(
                    title: String(localized: "Moved to Trash"),
                    detail: String(localized: "\(movedFiles.count) files totaling \(format(movedFiles.reduce(0) { $0 + $1.size })) were moved. Every protected copy remains in place.")
                )
            } else {
                actionMessage = DuplicateActionMessage(
                    title: movedFiles.isEmpty ? String(localized: "Nothing was moved") : String(localized: "Some files were not moved"),
                    detail: failures.joined(separator: "\n")
                )
            }
        }
    }

    private func applyTrashResult(_ movedFiles: [DuplicateFile]) {
        guard let currentResult = result else { return }
        let movedIDs = Set(movedFiles.map(\.url))
        let remainingGroups = currentResult.groups.compactMap { group -> DuplicateGroup? in
            let remaining = group.files.filter { !movedIDs.contains($0.url) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(digest: group.digest, files: remaining)
        }
        result = DuplicateScanResult(
            folder: currentResult.folder,
            groups: remainingGroups,
            skippedFiles: currentResult.skippedFiles,
            filesInspected: currentResult.filesInspected,
            bytesHashed: currentResult.bytesHashed
        )
        selectedIDs.subtract(movedIDs)
        expandedGroupIDs.formIntersection(Set(remainingGroups.map(\.id)))
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DuplicateFinderView: View {
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    @ObservedObject var model: DuplicateFinderViewModel
    @State private var showsTrashConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            content
            if model.result?.groups.isEmpty == false {
                Divider()
                selectionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Duplicate Finder")
        .confirmationDialog(
            "Move selected duplicates to Trash?",
            isPresented: $showsTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                model.moveSelectedToTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.selectedIDs.count) files totaling \(format(model.selectedSize)) will be moved to Trash. The protected copy in every group stays in place.")
        }
        .alert(item: $model.actionMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Finder").font(.title2.weight(.semibold))
                if let folder = model.selectedFolder {
                    Label(folder.path, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                }
            }
            Spacer(minLength: 16)
            if model.state == .scanning {
                Button("Cancel", role: .cancel) {
                    model.cancelScan()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Stops scanning without changing any files")
            } else {
                Button {
                    chooseFolder()
                } label: {
                    Label(model.result == nil ? "Choose Folder" : "Scan Another Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(model.isMovingToTrash)
                .accessibilityHint("Opens a folder picker")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .failed(let message):
            failureState(message)
        case .finished:
            if let result = model.result, result.groups.isEmpty {
                emptyResult(result)
            } else if let result = model.result {
                resultContent(result)
            } else {
                idleState
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Find copies that are exactly the same").font(.headline)
            Text("Choose a folder. PureMac compares file sizes and SHA-256 content hashes. Nothing is selected or removed automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.progress.phase == .discovering ? "Looking through files" : "Verifying possible matches")
                .font(.headline)
            ProgressView(value: model.progress.fractionCompleted)
                .progressViewStyle(.linear)
            Text(progressSummary).font(.callout.monospacedDigit())
            if let currentURL = model.progress.currentURL {
                Text(verbatim: currentURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 460)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Label("Scan could not finish", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let folder = model.selectedFolder {
                Button("Try Again") { model.startScan(folder) }
                    .disabled(model.isMovingToTrash)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyResult(_ result: DuplicateScanResult) -> some View {
        VStack(spacing: 8) {
            Label("No exact duplicates found", systemImage: "checkmark.circle")
                .font(.headline)
            Text("Inspected \(result.filesInspected.formatted()) files in \(result.folder.lastPathComponent). \(skippedSummary(result.skippedFiles))")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again") { model.startScan(result.folder) }
                .disabled(model.isMovingToTrash)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func resultContent(_ result: DuplicateScanResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(String(localized: "\(format(result.reclaimableSize)) reviewable"))
                    .font(.headline)
                LabeledContent("Duplicate groups", value: result.groups.count.formatted())
                    .fixedSize()
                LabeledContent("Matching files", value: result.duplicateFileCount.formatted())
                    .fixedSize()
                Spacer(minLength: 2)
                Button {
                    model.startScan(result.folder)
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isMovingToTrash)
            }
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            Divider()
            List {
                ForEach(result.groups) { group in
                    groupHeader(group)
                        .listRowBackground(Color.primary.opacity(0.045))
                    if model.expandedGroupIDs.contains(group.id) {
                        ForEach(group.files) { file in
                            fileRow(file, in: group)
                                .listRowSeparator(.visible)
                        }
                    }
                }
                if !result.skippedFiles.isEmpty {
                    skippedItems(result.skippedFiles)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 32)
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleExpanded(group)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(model.expandedGroupIDs.contains(group.id) ? .degrees(90) : .zero)
                        .frame(width: 12)
                    Text(group.keeper.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.expandedGroupIDs.contains(group.id) ? "Collapse duplicate group" : "Expand duplicate group")
            .accessibilityValue(Text(verbatim: group.keeper.url.lastPathComponent))
            Text("\(group.files.count) exact copies · \(format(group.fileSize)) each")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(model.groupCandidatesSelected(group) ? "Clear" : "Select copies") {
                model.toggleGroupSelection(group)
            }
            .controlSize(.small)
            .disabled(model.isMovingToTrash)
        }
        .padding(.vertical, 3)
    }

    private func fileRow(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        let keeper = file.url == group.keeper.url
        return HStack(spacing: 9) {
            if keeper {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityLabel("Protected copy")
            } else {
                Toggle("", isOn: selectionBinding(for: file.url))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 18)
                    .disabled(model.isMovingToTrash)
                    .accessibilityLabel("Select \(file.url.lastPathComponent)")
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: file.url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(verbatim: file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
            }
            Spacer(minLength: 4)
            if let modifiedAt = file.modifiedAt {
                Text(modifiedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if keeper {
                    Text("Protected copy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Keep This Copy") {
                        withAnimation(motionEnabled ? MotionTokens.snappy : nil) {
                            model.keep(file.url, in: group.id)
                        }
                    }
                    .accessibilityValue(Text(verbatim: file.url.path))
                    .controlSize(.small)
                    .disabled(model.isMovingToTrash)
                }
            }
            .frame(minWidth: 84, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.forward.square")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
            .help("Reveal in Finder")
        }
        .padding(.leading, 14)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func skippedItems(_ skippedFiles: [DuplicateSkippedFile]) -> some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(skippedFiles) { file in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Tint.orange)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(file.detail.map { "\(file.reason.label): \($0)" } ?? file.reason.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        } label: {
                            Image(systemName: "arrow.forward.square")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reveal skipped item in Finder")
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skipped items")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(skippedFiles.count) unsafe or unavailable items were not scanned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedIDs.isEmpty ? "Nothing selected" : "\(model.selectedIDs.count) selected")
                    .font(.callout.weight(.medium))
                if !model.selectedIDs.isEmpty {
                    Text("\(format(model.selectedSize)) will move to Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Spacer(minLength: 4)
            Button("Select All Copies") { model.selectAllCopies() }
                .disabled(model.isMovingToTrash)
            if !model.selectedIDs.isEmpty {
                Button("Clear Selection") { model.selectedIDs.removeAll() }
                    .disabled(model.isMovingToTrash)
            }
            Button(role: .destructive) {
                showsTrashConfirmation = true
            } label: {
                if model.isMovingToTrash {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            .disabled(model.selectedIDs.isEmpty || model.isMovingToTrash || model.state == .scanning)
            .accessibilityHint("Shows a confirmation before moving the selected copies")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var progressSummary: String {
        switch model.progress.phase {
        case .discovering:
            return String(localized: "\(model.progress.filesInspected.formatted()) files inspected")
        case .hashing:
            return String(localized: "\(model.progress.filesHashed.formatted()) of \(model.progress.filesToHash.formatted()) candidates · \(format(model.progress.bytesHashed)) verified")
        }
    }

    private func selectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { model.selectedIDs.contains(url) },
            set: { selected in
                if selected {
                    model.selectedIDs.insert(url)
                } else {
                    model.selectedIDs.remove(url)
                }
            }
        )
    }

    private func toggleExpanded(_ group: DuplicateGroup) {
        withAnimation(motionEnabled ? MotionTokens.gentle : nil) {
            if model.expandedGroupIDs.contains(group.id) {
                model.expandedGroupIDs.remove(group.id)
            } else {
                model.expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func chooseFolder() {
        guard !model.isMovingToTrash else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder to check for duplicate files")
        panel.prompt = String(localized: "Scan Folder")
        panel.message = String(localized: "PureMac reads the selected folder and does not change anything during a scan.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let folder = panel.url {
            model.startScan(folder)
        }
    }

    private func skippedSummary(_ skippedFiles: [DuplicateSkippedFile]) -> String {
        skippedFiles.isEmpty
            ? String(localized: "Every eligible file was checked.")
            : String(localized: "\(skippedFiles.count) unsafe or unavailable items were skipped.")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DuplicateActionMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
