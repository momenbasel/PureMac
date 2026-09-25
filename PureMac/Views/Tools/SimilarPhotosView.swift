import AppKit
import SwiftUI

@MainActor
final class SimilarPhotosViewModel: ObservableObject {
    enum Phase {
        case idle
        case scanning
        case loaded
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var folder: URL?
    @Published private(set) var result: SimilarPhotoScanResult?
    @Published private(set) var progress: SimilarPhotoScanProgress?

    private let finder: SimilarPhotoFinder
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    init(finder: SimilarPhotoFinder = SimilarPhotoFinder()) {
        self.finder = finder
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a photo folder")
        panel.message = String(localized: "PureMac compares local image thumbnails without changing your photos.")
        panel.prompt = String(localized: "Scan Photos")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(folder: url.standardizedFileURL)
    }

    func rescan() {
        guard let folder else { return }
        startScan(folder: folder)
    }

    func cancel() {
        guard isScanning else { return }
        scanTask?.cancel()
        phase = .cancelled
        progress = nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startScan(folder: URL) {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        self.folder = folder
        result = nil
        progress = SimilarPhotoScanProgress(
            phase: .discovering,
            entriesVisited: 0,
            candidatesFound: 0,
            photosAnalyzed: 0,
            currentURL: folder
        )
        phase = .scanning

        scanTask = Task { [weak self, finder] in
            do {
                let result = try await finder.scan(folder: folder) { [weak self] progress in
                    await self?.receive(progress, scanID: id)
                }
                guard let self, self.scanID == id, !Task.isCancelled else { return }
                self.result = result
                self.progress = nil
                self.phase = .loaded
            } catch is CancellationError {
                guard let self, self.scanID == id, self.isScanning else { return }
                self.progress = nil
                self.phase = .cancelled
            } catch {
                guard let self, self.scanID == id else { return }
                self.progress = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func receive(_ progress: SimilarPhotoScanProgress, scanID: UUID) {
        guard self.scanID == scanID, isScanning else { return }
        self.progress = progress
    }
}

struct SimilarPhotosView: View {
    @StateObject private var model: SimilarPhotosViewModel

    init(finder: SimilarPhotoFinder = SimilarPhotoFinder()) {
        _model = StateObject(wrappedValue: SimilarPhotosViewModel(finder: finder))
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if let folder = model.folder {
                        locationCard(folder)
                    }
                    content
                }
                .padding(24)
                .frame(maxWidth: 1040, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Similar Photos")
        .onDisappear {
            model.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(systemName: "photo.stack.fill", tint: Tint.pink, size: 48, corner: 13, vivid: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Similar Photos")
                    .font(.system(size: 25, weight: .bold))
                Text("Find visually related shots in a folder and review them side by side.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.chooseFolder()
            } label: {
                Label(model.folder == nil ? String(localized: "Choose Folder") : String(localized: "Choose Another Folder"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.pink)
            .controlSize(.large)
            .disabled(model.isScanning)
        }
    }

    private func locationCard(_ folder: URL) -> some View {
        CardSurface(padding: 11, elevation: .flat, tint: Tint.pink) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Tint.pink)
                Text(folder.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    model.reveal(folder)
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
                title: "Photos could not be compared",
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: Tint.orange
            )
        case .cancelled:
            messageState(
                title: "Scan stopped",
                message: String(localized: "No photos were changed. You can scan the folder again at any time."),
                systemImage: "stop.circle",
                tint: .secondary
            )
        }
    }

    private var idleState: some View {
        CardSurface(padding: 32, elevation: .standard, tint: Tint.pink) {
            VStack(spacing: 15) {
                IconTile(systemName: "photo.on.rectangle.angled", tint: Tint.pink, size: 62, corner: 17)
                Text("Choose a folder of photos")
                    .font(.system(size: 19, weight: .semibold))
                Text("PureMac builds small local thumbnails, compares their visual structure and color, then groups likely matches for review.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                HStack(spacing: 8) {
                    StatusChip(label: String(localized: "Review only"), systemImage: "eye", tint: Tint.green)
                    StatusChip(label: String(localized: "500 photo limit"), systemImage: "photo.stack", tint: Tint.pink)
                    StatusChip(label: String(localized: "Local files"), systemImage: "lock.shield", tint: Tint.blue)
                }
                Text("Symbolic links, app packages, hidden files and cloud-only placeholders are skipped. Photos are never uploaded or deleted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var scanningState: some View {
        CardSurface(padding: 24, elevation: .standard, tint: Tint.pink) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progressTitle)
                            .font(.system(size: 16, weight: .semibold))
                        Text(model.progress?.currentURL?.lastPathComponent ?? String(localized: "Preparing visual comparison"))
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
                    .tint(Tint.pink)

                HStack(spacing: 8) {
                    StatusChip(
                        label: String(localized: "\(model.progress?.entriesVisited ?? 0) items"),
                        systemImage: "doc.on.doc",
                        tint: Tint.pink
                    )
                    StatusChip(
                        label: String(localized: "\(model.progress?.candidatesFound ?? 0) photos"),
                        systemImage: "photo",
                        tint: Tint.pink
                    )
                    if let progress = model.progress, progress.photosAnalyzed > 0 {
                        StatusChip(
                            label: String(localized: "\(progress.photosAnalyzed) compared"),
                            systemImage: "viewfinder",
                            tint: Tint.blue
                        )
                    }
                }
            }
        }
    }

    private var progressTitle: String {
        switch model.progress?.phase {
        case .discovering, .none:
            return String(localized: "Finding local photos")
        case .analyzing:
            return String(localized: "Building visual signatures")
        case .comparing:
            return String(localized: "Grouping similar shots")
        }
    }

    private func resultView(_ result: SimilarPhotoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCard(result)

            CardSurface(padding: 14, elevation: .flat, tint: Tint.blue) {
                HStack(alignment: .top, spacing: 11) {
                    IconTile(systemName: "eye.fill", tint: Tint.blue, size: 30, corner: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Review the groups before acting")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Similarity is a visual estimate, not proof that two files are identical. Use Show in Finder to compare originals at full quality.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if result.groups.isEmpty {
                CardSurface(padding: 28, elevation: .standard) {
                    VStack(spacing: 12) {
                        IconTile(systemName: "checkmark.circle.fill", tint: Tint.green, size: 52, corner: 14)
                        Text("No similar groups found")
                            .font(.system(size: 18, weight: .semibold))
                        Text("The analyzed photos did not meet PureMac's visual similarity threshold.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            } else {
                SectionHeader("Suggested groups")
                ForEach(Array(result.groups.enumerated()), id: \.element.id) { index, group in
                    SimilarPhotoGroupCard(index: index + 1, group: group, onReveal: model.reveal)
                }
            }
        }
    }

    private func summaryCard(_ result: SimilarPhotoScanResult) -> some View {
        CardSurface(padding: 18, elevation: .standard, tint: Tint.pink) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(result.groups.count)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Tint.pink)
                    Text(result.groups.count == 1 ? String(localized: "similar group") : String(localized: "similar groups"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 50)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusChip(label: String(localized: "\(result.photosAnalyzed) analyzed"), systemImage: "viewfinder", tint: Tint.pink)
                        StatusChip(label: String(localized: "\(result.matchedPhotoCount) matched"), systemImage: "photo.stack", tint: Tint.blue)
                    }
                    HStack(spacing: 8) {
                        StatusChip(label: Self.format(result.matchedPhotoSize), systemImage: "internaldrive", tint: Tint.purple)
                        if result.skippedItems > 0 {
                            StatusChip(label: String(localized: "\(result.skippedItems) skipped"), systemImage: "forward", tint: Tint.orange)
                        }
                    }
                }

                Spacer()

                StatusChip(
                    label: result.isPartial ? String(localized: "Sample limit reached") : String(localized: "Scan complete"),
                    systemImage: result.isPartial ? "exclamationmark.triangle" : "checkmark.circle",
                    tint: result.isPartial ? Tint.orange : Tint.green
                )
            }
        }
    }

    private func messageState(title: LocalizedStringKey, message: String, systemImage: String, tint: Color) -> some View {
        CardSurface(padding: 30, elevation: .standard, tint: tint) {
            VStack(spacing: 13) {
                IconTile(systemName: systemImage, tint: tint, size: 54, corner: 15)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                if model.folder != nil {
                    Button("Scan Again") {
                        model.rescan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.pink)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SimilarPhotoGroupCard: View {
    let index: Int
    let group: SimilarPhotoGroup
    let onReveal: (URL) -> Void

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 12)]

    var body: some View {
        CardSurface(padding: 0, elevation: .standard) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    IconTile(systemName: "photo.stack.fill", tint: Tint.pink, size: 32, corner: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group \(index)")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(group.photos.count) photos · \(Self.format(group.totalSize))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusChip(
                        label: String(localized: "\(Int((group.similarity * 100).rounded()))% visual score"),
                        systemImage: "viewfinder",
                        tint: Tint.pink
                    )
                }
                .padding(16)

                Divider()

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(group.photos) { photo in
                        SimilarPhotoTile(photo: photo, onReveal: { onReveal(photo.url) })
                    }
                }
                .padding(14)
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SimilarPhotoTile: View {
    let photo: SimilarPhoto
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                if let image = NSImage(data: photo.thumbnailData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            Text(photo.url.lastPathComponent)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(photo.url.path)

            HStack(spacing: 5) {
                Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
                Text("·")
                Text(Self.format(photo.size))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)

            Button(action: onReveal) {
                Label("Show in Finder", systemImage: "arrow.forward.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Show \(photo.url.lastPathComponent) in Finder")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .contextMenu {
            Button("Show in Finder", action: onReveal)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
