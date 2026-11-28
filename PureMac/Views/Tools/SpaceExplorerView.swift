import AppKit
import SwiftUI

@MainActor
final class SpaceExplorerViewModel: ObservableObject {
    enum Phase {
        case idle
        case scanning
        case loaded
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: StorageScanResult?
    @Published private(set) var progress: StorageScanProgress?
    @Published private(set) var currentURL: URL?
    @Published fileprivate(set) var selectedEntry: URL?
    @Published var nameFilter = "" {
        didSet {
            if oldValue != nameFilter { scrollAnchor = nil }
        }
    }

    private(set) var scrollAnchor: URL?

    private struct HistoryEntry {
        let result: StorageScanResult
        let selectedEntry: URL
        let scrollAnchor: URL?
        let nameFilter: String
    }

    private var history: [HistoryEntry] = []

    private let explorer: StorageExplorer
    private(set) var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    init(explorer: StorageExplorer = StorageExplorer()) {
        self.explorer = explorer
    }

    private var trimmedFilter: String {
        nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredEntries: [StorageEntry] {
        guard let result else { return [] }
        let query = trimmedFilter
        guard !query.isEmpty else { return result.entries }
        return result.entries.filter { $0.name.localizedStandardContains(query) }
    }

    var canGoBack: Bool { !history.isEmpty }
    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder to inspect")
        panel.message = String(localized: "PureMac measures allocated disk space without changing files.")
        panel.prompt = String(localized: "Inspect")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspect(url)
    }

    func inspect(_ url: URL) {
        history.removeAll()
        nameFilter = ""
        selectedEntry = nil
        scrollAnchor = nil
        startScan(at: url.standardizedFileURL)
    }

    func open(_ entry: StorageEntry) {
        guard entry.isDirectory, let result, result.entries.contains(entry) else { return }
        history.append(HistoryEntry(result: result, selectedEntry: entry.url,
                                    scrollAnchor: scrollAnchor, nameFilter: nameFilter))
        if history.count > 12 { history.removeFirst() }
        nameFilter = ""
        selectedEntry = nil
        scrollAnchor = nil
        startScan(at: entry.url)
    }

    func select(_ entry: StorageEntry) {
        guard result?.entries.contains(entry) == true else { return }
        let query = trimmedFilter
        if !query.isEmpty && !entry.name.localizedStandardContains(query) { nameFilter = "" }
        selectedEntry = entry.url
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        cancel()
        currentURL = previous.result.rootURL
        nameFilter = previous.nameFilter
        selectedEntry = previous.selectedEntry
        scrollAnchor = previous.scrollAnchor
        result = previous.result
        phase = .loaded
    }

    func rememberScrollAnchor(_ anchor: URL?, in folder: URL) {
        guard folder == currentURL, result != nil else { return }
        scrollAnchor = anchor
    }

    func rescan() {
        guard let url = currentURL else { return }
        startScan(at: url)
    }

    func cancel() {
        guard isScanning else { return }
        scanID = UUID()
        scanTask?.cancel()
        progress = nil
        phase = .cancelled
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startScan(at url: URL) {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        currentURL = url
        result = nil
        progress = StorageScanProgress(
            rootURL: url,
            currentURL: url,
            allocatedSize: 0,
            scannedItemCount: 0,
            inaccessibleCount: 0,
            skippedCount: 0
        )
        phase = .scanning

        scanTask = Task { [self, explorer] in
            do {
                let result = try await explorer.scan(at: url) { progress in
                    Task { @MainActor [self] in
                        guard self.scanID == id, self.isScanning else { return }
                        self.progress = progress
                    }
                }
                guard self.scanID == id, !Task.isCancelled else { return }
                if let selected = self.selectedEntry, !result.entries.contains(where: { $0.url == selected }) {
                    self.selectedEntry = nil
                }
                self.result = result
                self.progress = nil
                self.phase = .loaded
            } catch is CancellationError {
                guard self.scanID == id, self.isScanning else { return }
                self.phase = .cancelled
            } catch {
                guard self.scanID == id else { return }
                self.progress = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct SpaceExplorerView: View {
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    @ObservedObject var model: SpaceExplorerViewModel
    @FocusState private var filterFocused: Bool
    @State private var chartDestination: URL?
    let findDuplicates: (URL) -> Void
    var canFindDuplicates: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            if let currentURL = model.currentURL {
                locationBar(currentURL)
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Space Explorer")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Space Explorer")
                .font(.title2.weight(.semibold))
            Spacer(minLength: 8)
            if let result = model.result, !result.entries.isEmpty {
                nameFilterField
            }
            Button {
                model.chooseFolder()
            } label: {
                Text(model.currentURL == nil ? "Choose Folder" : "Choose Another Folder")
            }
            .disabled(model.isScanning)
        }
    }

    private var nameFilterField: some View {
        HStack(spacing: 6) {
            Button {
                filterFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Filter by name")
            TextField("Filter by name", text: $model.nameFilter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onExitCommand {
                    if model.nameFilter.isEmpty { filterFocused = false }
                    else { model.nameFilter = "" }
                }
                .accessibilityIdentifier("storage.nameFilter")
            if !model.nameFilter.isEmpty {
                Button {
                    model.nameFilter = ""
                    filterFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 200)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(filterFocused ? Color.accentColor : Color.primary.opacity(0.17), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func locationBar(_ url: URL) -> some View {
        HStack(spacing: 9) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoBack)
            .accessibilityLabel("Back")
            .help("Back")
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: url.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.path)
            Spacer(minLength: 4)
            Button("Find Duplicates Here") { findDuplicates(url) }
                .disabled(!canFindDuplicates || model.result == nil)
            Button {
                model.reveal(url)
            } label: {
                Label("Show in Finder", systemImage: "arrow.forward.square")
            }
            .help("Show in Finder")
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan")
            .disabled(model.isScanning)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .loaded:
            if let result = model.result {
                resultView(result)
            } else {
                idleState
            }
        case .failed(let message):
            messageState(
                title: "Folder could not be inspected",
                message: message,
                systemImage: "exclamationmark.folder",
                tint: Tint.orange
            )
        case .cancelled:
            messageState(
                title: "Scan stopped",
                message: String(localized: "No files were changed. Rescan this folder when you are ready."),
                systemImage: "stop.circle",
                tint: .secondary
            )
        }
    }

    private var idleState: some View {
        VStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Choose where to look")
                .font(.headline)
            Text("Select any folder to see which files and subfolders occupy the most disk space.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 365)
            Text("Symbolic links and cloud-only items are excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Measuring allocated space").font(.headline)
                Spacer()
                Button("Stop") { model.cancel() }
            }
            ProgressView().progressViewStyle(.linear)
            Text(model.progress?.currentURL.path ?? String(localized: "Preparing scan"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text("\(model.progress?.scannedItemCount ?? 0) items")
                Text(Self.format(model.progress?.allocatedSize ?? 0))
                if let progress = model.progress, progress.skippedCount > 0 {
                    Text("\(progress.skippedCount) skipped")
                }
                if let progress = model.progress, progress.inaccessibleCount > 0 {
                    Text("\(progress.inaccessibleCount) inaccessible")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: StorageScanResult) -> some View {
        let restoreAnchor = model.scrollAnchor
        let entries = model.filteredEntries
        let largest = Array(result.entries.prefix(4))
        return ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 0) {
                storageSummary(result, largest: largest) { entry in
                    filterFocused = false
                    model.select(entry)
                    chartDestination = entry.url
                }
                Divider()
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Name")
                        if !model.nameFilter.isEmpty {
                            Text("\(entries.count) of \(result.entries.count) items shown")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Size").frame(width: 80, alignment: .trailing)
                    Text(verbatim: "%").frame(width: 56, alignment: .trailing)
                        .accessibilityLabel("Share of scanned space")
                    Color.clear.frame(width: 24)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .frame(height: 26)
                .background(.bar)
                Divider()

                if entries.isEmpty {
                    VStack(spacing: 5) {
                        Text(result.entries.isEmpty ? "No measurable items" : "No matching items")
                            .font(.headline)
                        if result.entries.isEmpty {
                            Text("This folder is empty or its contents were excluded from the scan.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(get: { model.selectedEntry }, set: { model.selectedEntry = $0 })) {
                        ForEach(entries) { entry in
                            StorageEntryRow(
                                entry: entry, totalSize: result.totalAllocatedSize,
                                onOpen: { model.open(entry) },
                                onReveal: { model.reveal(entry.url) },
                                onFindDuplicates: canFindDuplicates ? { findDuplicates(entry.url) } : nil
                            )
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                            .id(entry.url)
                            .tag(entry.url)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: VisibleStorageRows.self,
                                        value: [entry.url: geometry.frame(in: .named("storageResults"))]
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 34)
                    .coordinateSpace(name: "storageResults")
                    .onPreferenceChange(VisibleStorageRows.self) { rows in
                        guard !rows.isEmpty else { return }
                        let uppermost = rows.filter { $0.value.maxY > 0 }
                            .min { $0.value.minY < $1.value.minY }
                        model.rememberScrollAnchor(uppermost?.key, in: result.rootURL)
                    }
                }
            }
            .onAppear {
                if let restoreAnchor { reader.scrollTo(restoreAnchor, anchor: .top) }
            }
            .onChange(of: chartDestination) { destination in
                guard let destination else { return }
                withAnimation(motionEnabled ? MotionTokens.gentle : nil) {
                    reader.scrollTo(destination, anchor: .center)
                }
                chartDestination = nil
            }
            .onChange(of: model.nameFilter) { _ in
                if filterFocused, let first = entries.first { reader.scrollTo(first.url, anchor: .top) }
            }
        }
        .id(result.rootURL)
    }

    private func storageSummary(
        _ result: StorageScanResult, largest: [StorageEntry], select: @escaping (StorageEntry) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Self.format(result.totalAllocatedSize)).font(.headline).monospacedDigit()
                Text("allocated in this folder").foregroundStyle(.secondary)
                Spacer()
                Text(StorageEntryRow.fileCountLabel(result.fileCount))
                Text(verbatim: "·").accessibilityHidden(true)
                Text(StorageEntryRow.folderCountLabel(result.directoryCount))
            }
            .font(.callout)
            if result.totalAllocatedSize > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(Array(largest.enumerated()), id: \.element.url) { index, entry in
                            let fraction = Double(entry.allocatedSize) / Double(result.totalAllocatedSize)
                            if fraction > 0 {
                                Button { select(entry) } label: {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(1 - Double(index) * 0.16))
                                        .frame(width: geometry.size.width * fraction)
                                        .overlay(alignment: .trailing) {
                                            Rectangle().fill(.background).frame(width: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .help(Text(verbatim: "\(entry.name) · \(Self.format(entry.allocatedSize))"))
                                .accessibilityLabel(Text(verbatim: entry.name))
                                .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0...1)))))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 9)
                .background(Color.secondary.opacity(0.17))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            HStack {
                Text("Sizes are estimates. Fully shared copies count once.")
                if result.isPartial {
                    Spacer()
                    Label("\(result.skippedCount) skipped · \(result.inaccessibleCount) inaccessible",
                          systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func messageState(title: LocalizedStringKey, message: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Rescan") { model.rescan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct VisibleStorageRows: PreferenceKey {
    static var defaultValue: [URL: CGRect] { [:] }

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct StorageEntryRow: View {
    let entry: StorageEntry
    let totalSize: Int64
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onFindDuplicates: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if entry.isDirectory {
                Button(action: onOpen) { nameColumn }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                nameColumn.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Self.format(entry.allocatedSize))
                .frame(width: 80, alignment: .trailing)
            Text(share.formatted(.percent.precision(.fractionLength(0...1))))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Button(action: onReveal) {
                Image(systemName: "arrow.forward.square")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(entry.name) in Finder")
        }
        .font(.body)
        .monospacedDigit()
        .contentShape(Rectangle())
        .contextMenu {
            if entry.isDirectory {
                Button("Open Folder", action: onOpen)
                if let onFindDuplicates { Button("Find Duplicates Here", action: onFindDuplicates) }
            }
            Button("Show in Finder", action: onReveal)
        }
    }

    private var nameColumn: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : (entry.isPackage ? "shippingbox" : "doc"))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                if entry.isDirectory || entry.isPackage || entry.isPartial {
                    HStack(spacing: 6) {
                        Text(detailText)
                        if entry.skippedCount > 0 { Text("\(entry.skippedCount) skipped") }
                        if entry.inaccessibleCount > 0 { Text("\(entry.inaccessibleCount) inaccessible") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var share: Double {
        totalSize > 0 ? min(1, Double(entry.allocatedSize) / Double(totalSize)) : 0
    }

    private var detailText: String {
        if entry.isPackage {
            return String(localized: "Package · \(Self.fileCountLabel(entry.fileCount))")
        }
        if entry.isDirectory {
            let childFolderCount = max(0, entry.directoryCount - 1)
            return "\(Self.fileCountLabel(entry.fileCount)) · \(Self.folderCountLabel(childFolderCount))"
        }
        return String(localized: "File")
    }

    static func fileCountLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    static func folderCountLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 folder") : String(localized: "\(count) folders")
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
