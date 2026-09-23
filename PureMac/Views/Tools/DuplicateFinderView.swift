import AppKit
import SwiftUI

struct DuplicateFinderView: View {
    private enum ScreenState: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private let finder: DuplicateFinder
    @State private var state: ScreenState = .idle
    @State private var result: DuplicateScanResult?
    @State private var selectedFolder: URL?
    @State private var progress = DuplicateScanProgress(
        phase: .discovering,
        filesInspected: 0,
        filesToHash: 0,
        filesHashed: 0,
        bytesHashed: 0,
        currentURL: nil
    )
    @State private var selectedIDs: Set<URL> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var scanGeneration = UUID()
    @State private var scanTask: Task<Void, Never>?
    @State private var trashTask: Task<Void, Never>?
    @State private var isMovingToTrash = false
    @State private var showsTrashConfirmation = false
    @State private var actionMessage: ActionMessage?

    init(finder: DuplicateFinder = DuplicateFinder()) {
        self.finder = finder
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                header
                content
                if result?.groups.isEmpty == false {
                    selectionBar
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            "Move selected duplicates to Trash?",
            isPresented: $showsTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                moveSelectedToTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedIDs.count) files totaling \(format(selectedSize)) will be moved to Trash. The protected copy in every group stays in place.")
        }
        .alert(item: $actionMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            scanGeneration = UUID()
            scanTask?.cancel()
            trashTask?.cancel()
        }
    }

    private var header: some View {
        CardSurface(padding: 18, elevation: .flat, tint: Tint.accent) {
            HStack(spacing: 14) {
                IconTile(systemName: "square.on.square", tint: Tint.accent, size: 42, corner: 11)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Finder")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                if state == .scanning {
                    Button("Cancel", role: .cancel) {
                        scanTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops scanning without changing any files")
                } else {
                    Button {
                        chooseFolder()
                    } label: {
                        Label(result == nil ? "Choose Folder" : "Scan Another Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.accent)
                    .disabled(isMovingToTrash)
                    .accessibilityHint("Opens a folder picker")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .failed(let message):
            failureState(message)
        case .finished:
            if let result, result.groups.isEmpty {
                emptyResult(result)
            } else if let result {
                resultContent(result)
            } else {
                idleState
            }
        }
    }

    private var idleState: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Tint.accent.opacity(0.09))
                        .frame(width: 116, height: 100)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 44, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Tint.accent)
                }
                Text("Find copies that are exactly the same")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose a folder. Qpure compares file sizes first, then verifies matching files byte for byte. Nothing is selected or removed automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose a Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
                .controlSize(.large)
                .disabled(isMovingToTrash)
                .padding(.top, 3)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        CardSurface(padding: 28, elevation: .flat, tint: Tint.accent) {
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle()
                        .stroke(Tint.accent.opacity(0.14), lineWidth: 9)
                        .frame(width: 104, height: 104)
                    if let fraction = progress.fractionCompleted {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Tint.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 104, height: 104)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Tint.accent)
                    }
                    Image(systemName: progress.phase == .discovering ? "folder" : "number")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Tint.accent)
                }
                VStack(spacing: 7) {
                    Text(progress.phase == .discovering ? "Looking through files" : "Verifying possible matches")
                        .font(.system(size: 18, weight: .semibold))
                    Text(progressSummary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let currentURL = progress.currentURL {
                        Text(currentURL.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 520)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progressSummary)
        }
    }

    private func failureState(_ message: String) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.red) {
            VStack(spacing: 14) {
                Spacer()
                IconTile(systemName: "exclamationmark.triangle.fill", tint: Tint.red, size: 54, corner: 14)
                Text("Scan could not finish")
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack {
                    if let folder = selectedFolder {
                        Button("Try Again") { startScan(folder) }
                            .buttonStyle(.borderedProminent)
                            .tint(Tint.accent)
                            .disabled(isMovingToTrash)
                    }
                    Button("Choose Another Folder") { chooseFolder() }
                        .buttonStyle(.bordered)
                        .disabled(isMovingToTrash)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyResult(_ result: DuplicateScanResult) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.green) {
            VStack(spacing: 14) {
                Spacer()
                IconTile(systemName: "checkmark.seal.fill", tint: Tint.green, size: 58, corner: 16)
                Text("No exact duplicates found")
                    .font(.system(size: 19, weight: .semibold))
                Text("Inspected \(result.filesInspected.formatted()) files in \(result.folder.lastPathComponent). \(skippedSummary(result.skippedFiles))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Button("Scan Again") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultContent(_ result: DuplicateScanResult) -> some View {
        VStack(spacing: 14) {
            summaryCard(result)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(result.groups) { group in
                        groupCard(group)
                    }
                    if !result.skippedFiles.isEmpty {
                        skippedCard(result.skippedFiles)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryCard(_ result: DuplicateScanResult) -> some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 0) {
                summaryMetric(value: result.groups.count.formatted(), label: "Duplicate groups", icon: "square.stack.3d.up", tint: Tint.accent)
                Divider().frame(height: 38)
                summaryMetric(value: result.duplicateFileCount.formatted(), label: "Matching files", icon: "doc.on.doc", tint: Tint.purple)
                Divider().frame(height: 38)
                summaryMetric(value: format(result.reclaimableSize), label: "Available to review", icon: "internaldrive", tint: Tint.green)
                Spacer(minLength: 10)
                Button("Rescan") { startScan(result.folder) }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash)
            }
        }
    }

    private func summaryMetric(value: String, label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            IconTile(systemName: icon, tint: tint, size: 30, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.accent) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(systemName: "doc.on.doc.fill", tint: Tint.accent, size: 34, corner: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.keeper.url.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(group.files.count) exact copies · \(format(group.fileSize)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusChip(label: "\(format(group.reclaimableSize)) reviewable", systemImage: "arrow.down.circle", tint: Tint.green)
                    Button(groupCandidatesSelected(group) ? "Clear" : "Select copies") {
                        toggleGroupSelection(group)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMovingToTrash)
                    Button {
                        toggleExpanded(group)
                    } label: {
                        Image(systemName: expandedGroupIDs.contains(group.id) ? "chevron.up" : "chevron.down")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedGroupIDs.contains(group.id) ? "Collapse duplicate group" : "Expand duplicate group")
                }
                .padding(14)

                if expandedGroupIDs.contains(group.id) {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file, keeper: index == 0)
                            if index < group.files.count - 1 {
                                Divider().padding(.leading, 49)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, keeper: Bool) -> some View {
        HStack(spacing: 11) {
            if keeper {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tint.green)
                    .frame(width: 18)
                    .accessibilityLabel("Protected copy")
            } else {
                Toggle("", isOn: selectionBinding(for: file.url))
                    .labelsHidden()
                    .toggleStyle(AnimatedCheckboxStyle(tint: Tint.accent))
                    .disabled(isMovingToTrash)
                    .accessibilityLabel("Select \(file.url.lastPathComponent)")
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 13, weight: keeper ? .semibold : .regular))
                        .lineLimit(1)
                    if keeper {
                        StatusChip(label: "Keep", systemImage: "lock.fill", tint: Tint.green)
                    }
                }
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let modifiedAt = file.modifiedAt {
                Text(modifiedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.forward.square")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func skippedCard(_ skippedFiles: [DuplicateSkippedFile]) -> some View {
        CardSurface(padding: 14, elevation: .flat, tint: Tint.orange) {
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
                    IconTile(systemName: "exclamationmark.triangle", tint: Tint.orange, size: 30, corner: 8)
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
    }

    private var selectionBar: some View {
        CardSurface(padding: 14, elevation: .raised, tint: selectedIDs.isEmpty ? nil : Tint.accent) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedIDs.isEmpty ? "Nothing selected" : "\(selectedIDs.count) selected")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(selectedIDs.isEmpty ? "Select the extra copies you want to review" : "\(format(selectedSize)) will move to Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedIDs.isEmpty {
                    Button("Clear Selection") { selectedIDs.removeAll() }
                        .buttonStyle(.borderless)
                        .disabled(isMovingToTrash)
                }
                Button {
                    showsTrashConfirmation = true
                } label: {
                    if isMovingToTrash {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 100)
                    } else {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.red)
                .disabled(selectedIDs.isEmpty || isMovingToTrash || state == .scanning)
                .accessibilityHint("Shows a confirmation before moving the selected copies")
            }
        }
    }

    private var headerSubtitle: String {
        if state == .scanning, let current = progress.currentURL {
            return current.deletingLastPathComponent().path
        }
        return selectedFolder?.path ?? String(localized: "Exact-match cleanup with a protected copy in every group")
    }

    private var progressSummary: String {
        switch progress.phase {
        case .discovering:
            return String(format: String(localized: "%@ files inspected"), progress.filesInspected.formatted())
        case .hashing:
            return String(format: String(localized: "%@ of %@ candidates · %@ verified"), progress.filesHashed.formatted(), progress.filesToHash.formatted(), format(progress.bytesHashed))
        }
    }

    private var selectedSize: Int64 {
        guard let result else { return 0 }
        return result.groups
            .flatMap(\.files)
            .filter { selectedIDs.contains($0.url) }
            .reduce(0) { $0 + $1.size }
    }

    private func selectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(url) },
            set: { selected in
                if selected {
                    selectedIDs.insert(url)
                } else {
                    selectedIDs.remove(url)
                }
            }
        )
    }

    private func groupCandidatesSelected(_ group: DuplicateGroup) -> Bool {
        group.files.dropFirst().allSatisfy { selectedIDs.contains($0.url) }
    }

    private func toggleGroupSelection(_ group: DuplicateGroup) {
        let candidateIDs = Set(group.files.dropFirst().map(\.url))
        if candidateIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(candidateIDs)
        } else {
            selectedIDs.formUnion(candidateIDs)
        }
    }

    private func toggleExpanded(_ group: DuplicateGroup) {
        withAnimation(MotionTokens.gentle) {
            if expandedGroupIDs.contains(group.id) {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func chooseFolder() {
        guard !isMovingToTrash else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder to check for duplicate files")
        panel.prompt = String(localized: "Scan Folder")
        panel.message = String(localized: "Qpure reads the selected folder and does not change anything during a scan.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let folder = panel.url {
            startScan(folder)
        }
    }

    private func startScan(_ folder: URL) {
        guard !isMovingToTrash else { return }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        selectedFolder = folder
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
        scanTask = Task { @MainActor in
            let usesScopedAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let scanResult = try await finder.scan(folder: folder) { update in
                    await MainActor.run {
                        guard scanGeneration == generation else { return }
                        progress = update
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

    private func moveSelectedToTrash() {
        guard let currentResult = result, !selectedIDs.isEmpty else { return }
        let generation = scanGeneration
        let folder = currentResult.folder
        let selectionSnapshot = selectedIDs
        isMovingToTrash = true
        trashTask = Task { @MainActor in
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
                if Task.isCancelled { return }
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
                  result?.folder == folder,
                  !Task.isCancelled else { return }
            applyTrashResult(movedFiles)
            if failures.isEmpty {
                actionMessage = ActionMessage(
                    title: String(localized: "Moved to Trash"),
                    detail: String(format: String(localized: "%lld files totaling %@ were moved. Every protected copy remains in place."), Int64(movedFiles.count), format(movedFiles.reduce(0) { $0 + $1.size }))
                )
            } else {
                actionMessage = ActionMessage(
                    title: String(localized: movedFiles.isEmpty ? "Nothing was moved" : "Some files were not moved"),
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

    private func skippedSummary(_ skippedFiles: [DuplicateSkippedFile]) -> String {
        skippedFiles.isEmpty
            ? String(localized: "Every eligible file was checked.")
            : String(format: String(localized: "%lld unsafe or unavailable items were skipped."), Int64(skippedFiles.count))
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ActionMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
