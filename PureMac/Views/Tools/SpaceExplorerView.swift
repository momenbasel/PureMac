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
    @Published private(set) var path: [URL] = []

    private let explorer: StorageExplorer
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    init(explorer: StorageExplorer = StorageExplorer()) {
        self.explorer = explorer
    }

    var currentURL: URL? { path.last }
    var canGoBack: Bool { path.count > 1 && !isScanning }
    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to inspect"
        panel.message = "PureMac measures allocated disk space without changing files."
        panel.prompt = "Inspect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = [url.standardizedFileURL]
        startScan(at: url)
    }

    func open(_ entry: StorageEntry) {
        guard entry.isDirectory, !isScanning else { return }
        let url = entry.url.standardizedFileURL
        path.append(url)
        startScan(at: url)
    }

    func goBack() {
        guard canGoBack else { return }
        path.removeLast()
        guard let url = path.last else { return }
        startScan(at: url)
    }

    func rescan() {
        guard let url = currentURL else { return }
        startScan(at: url)
    }

    func cancel() {
        guard isScanning else { return }
        scanTask?.cancel()
        phase = .cancelled
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startScan(at url: URL) {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
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
                guard self.scanID == id else { return }
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
    @StateObject private var model = SpaceExplorerViewModel()

    var body: some View {
        VStack(spacing: 14) {
            header

            if let currentURL = model.currentURL {
                locationBar(currentURL)
            }

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Space Explorer")
        .onDisappear {
            model.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemName: "internaldrive", tint: Tint.accent, size: 44, corner: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("Space Explorer")
                    .font(.system(size: 24, weight: .bold))
                Text("Inspect a folder by allocated disk space. Your files are never changed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.chooseFolder()
            } label: {
                Label(model.currentURL == nil ? "Choose Folder" : "Choose Another Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.accent)
            .controlSize(.large)
            .disabled(model.isScanning)
        }
    }

    private func locationBar(_ url: URL) -> some View {
        CardSurface(padding: 10, elevation: .flat, tint: Tint.accent) {
            HStack(spacing: 10) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canGoBack)
                .help("Back")

                Image(systemName: "folder.fill")
                    .foregroundStyle(Tint.accent)

                Text(url.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Button {
                    model.reveal(url)
                } label: {
                    Label("Show in Finder", systemImage: "arrow.forward.square")
                }
                .buttonStyle(.borderless)

                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
            }
        }
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
                message: "No files were changed. Rescan this folder when you are ready.",
                systemImage: "stop.circle",
                tint: .secondary
            )
        }
    }

    private var idleState: some View {
        CardSurface(padding: 28, elevation: .standard, tint: Tint.accent) {
            VStack(spacing: 12) {
                IconTile(systemName: "folder", tint: Tint.accent, size: 58, corner: 16)
                Text("Choose where to look")
                    .font(.system(size: 18, weight: .semibold))
                Text("Select any folder to see which files and subfolders occupy the most disk space.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("Symbolic links and cloud-only items are excluded.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        CardSurface(padding: 24, elevation: .standard, tint: Tint.accent) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measuring allocated space")
                            .font(.system(size: 16, weight: .semibold))
                        Text(model.progress?.currentURL.lastPathComponent ?? "Preparing scan")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Stop") {
                        model.cancel()
                    }
                    .buttonStyle(.bordered)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Tint.accent)

                HStack(spacing: 8) {
                    StatusChip(
                        label: "\(model.progress?.scannedItemCount ?? 0) items",
                        systemImage: "doc.on.doc",
                        tint: Tint.accent
                    )
                    StatusChip(
                        label: Self.format(model.progress?.allocatedSize ?? 0),
                        systemImage: "internaldrive",
                        tint: Tint.accent
                    )
                    if let progress = model.progress, progress.skippedCount > 0 {
                        StatusChip(label: "\(progress.skippedCount) skipped", systemImage: "forward", tint: Tint.orange)
                    }
                    if let progress = model.progress, progress.inaccessibleCount > 0 {
                        StatusChip(label: "\(progress.inaccessibleCount) inaccessible", systemImage: "lock", tint: Tint.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func resultView(_ result: StorageScanResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summaryCard(result)

                if result.entries.isEmpty {
                    CardSurface(padding: 24, elevation: .flat) {
                        HStack(spacing: 12) {
                            IconTile(systemName: "folder", tint: Tint.accent, size: 36, corner: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No measurable items")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("This folder is empty or its contents were excluded from the scan.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    SectionHeader("Largest items")
                    ForEach(result.entries) { entry in
                        StorageEntryRow(
                            entry: entry,
                            totalSize: result.totalAllocatedSize,
                            onOpen: { model.open(entry) },
                            onReveal: { model.reveal(entry.url) }
                        )
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private func summaryCard(_ result: StorageScanResult) -> some View {
        CardSurface(padding: 18, elevation: .standard, tint: Tint.accent) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.format(result.totalAllocatedSize))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Tint.accent)
                    Text("allocated in this folder")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 48)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusChip(label: "\(result.fileCount) files", systemImage: "doc", tint: Tint.accent)
                        StatusChip(label: "\(result.directoryCount) folders", systemImage: "folder", tint: Tint.accent)
                    }
                    HStack(spacing: 8) {
                        StatusChip(
                            label: "\(result.skippedCount) skipped",
                            systemImage: "forward",
                            tint: result.skippedCount == 0 ? Tint.green : Tint.orange
                        )
                        StatusChip(
                            label: "\(result.inaccessibleCount) inaccessible",
                            systemImage: "lock",
                            tint: result.inaccessibleCount == 0 ? Tint.green : Tint.orange
                        )
                    }
                }

                Spacer()

                StatusChip(
                    label: result.isPartial ? "Partial result" : "Complete",
                    systemImage: result.isPartial ? "exclamationmark.triangle" : "checkmark.circle",
                    tint: result.isPartial ? Tint.orange : Tint.green
                )
            }
        }
    }

    private func messageState(title: LocalizedStringKey, message: String, systemImage: String, tint: Color) -> some View {
        CardSurface(padding: 28, elevation: .standard, tint: tint) {
            VStack(spacing: 12) {
                IconTile(systemName: systemImage, tint: tint, size: 54, corner: 15)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("Rescan") {
                    model.rescan()
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StorageEntryRow: View {
    let entry: StorageEntry
    let totalSize: Int64
    let onOpen: () -> Void
    let onReveal: () -> Void

    var body: some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(spacing: 12) {
                Group {
                    if entry.isDirectory {
                        Button(action: onOpen) {
                            entryContent
                        }
                        .buttonStyle(.plain)
                    } else {
                        entryContent
                    }
                }
                .frame(maxWidth: .infinity)

                Button(action: onReveal) {
                    Image(systemName: "arrow.forward.square")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(entry.name) in Finder")
            }
        }
        .contextMenu {
            if entry.isDirectory {
                Button("Open Folder", action: onOpen)
            }
            Button("Show in Finder", action: onReveal)
        }
    }

    private var entryContent: some View {
        HStack(spacing: 12) {
            IconTile(
                systemName: entry.isDirectory ? "folder.fill" : (entry.isPackage ? "app.fill" : "doc.fill"),
                tint: Tint.accent,
                size: 34,
                corner: 9
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(entry.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isPartial {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Tint.orange)
                            .help("Some contents were skipped or inaccessible")
                    }
                }

                HStack(spacing: 8) {
                    Text(detailText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if entry.skippedCount > 0 {
                        Text("\(entry.skippedCount) skipped")
                            .foregroundStyle(Tint.orange)
                    }
                    if entry.inaccessibleCount > 0 {
                        Text("\(entry.inaccessibleCount) inaccessible")
                            .foregroundStyle(Tint.orange)
                    }
                }
                .font(.system(size: 11.5))

                StorageUsageBar(value: entry.allocatedSize, total: totalSize)
            }

            Text(Self.format(entry.allocatedSize))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 76, alignment: .trailing)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(Self.format(entry.allocatedSize))")
        .accessibilityHint(entry.isDirectory ? "Open folder" : (entry.isPackage ? "Package" : "File"))
    }

    private var detailText: String {
        if entry.isPackage {
            return "Package · \(Self.countLabel(entry.fileCount, singular: "file"))"
        }
        if entry.isDirectory {
            let childFolderCount = max(0, entry.directoryCount - 1)
            return "\(Self.countLabel(entry.fileCount, singular: "file")) · \(Self.countLabel(childFolderCount, singular: "folder"))"
        }
        return "File"
    }

    private static func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StorageUsageBar: View {
    let value: Int64
    let total: Int64

    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(total)))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(Tint.accent)
                    .frame(width: proxy.size.width * ratio)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Share of scanned space")
        .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
    }
}
