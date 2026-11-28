import SwiftUI

/// View-side grouping of discovered leftovers into CleanMyMac-style buckets.
/// Purely presentational — AppState's flat `discoveredFiles` stays the source
/// of truth so the removal/selection logic is untouched.
enum LeftoverGroup: String, CaseIterable, Identifiable {
    case application = "Application"
    case caches = "Caches"
    case appSupport = "Application Support"
    case preferences = "Preferences"
    case logs = "Logs"
    case containers = "Containers"
    case launchAgents = "Launch Agents"
    case other = "Other Files"

    var id: String { rawValue }

    static func categorize(_ url: URL) -> LeftoverGroup {
        let path = url.path
        if path.hasSuffix(".app") { return .application }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Application Support/") { return .appSupport }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Logs/") || path.contains("/DiagnosticReports/") { return .logs }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .containers }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgents }
        return .other
    }
}

struct AppFilesView: View {
    @EnvironmentObject var appState: AppState
    let app: InstalledApp

    @State private var collapsedGroups: Set<LeftoverGroup> = []
    /// One-pass size cache so group headers and the selected-size counter
    /// don't re-stat the disk on every render.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.interfaceMotionEnabled) private var motionEnabled

    private var totalSelectedSize: Int64 {
        appState.selectedFiles.reduce(Int64(0)) { total, url in
            total + (cachedSize(url) ?? 0)
        }
    }

    /// Discovered files bucketed for display, preserving the sorted order
    /// inside each bucket. Only non-empty groups are shown.
    private var groupedFiles: [(group: LeftoverGroup, urls: [URL])] {
        let buckets = Dictionary(grouping: appState.discoveredFiles, by: LeftoverGroup.categorize)
        return LeftoverGroup.allCases.compactMap { group in
            guard let urls = buckets[group], !urls.isEmpty else { return nil }
            return (group, urls)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // Content
            if appState.isScanningAppFiles {
                scanningState
            } else if appState.discoveredFiles.isEmpty {
                EmptyStateView(
                    "No Related Files",
                    systemImage: "checkmark.circle",
                    description: LocalizedStringKey(
                        String(format: String(localized: "No additional files found for %@."), app.appName)
                    ),
                    tint: Tint.green
                )
            } else {
                fileGroupsList

                actionBar
            }
        }
        .task(id: appState.discoveredFiles) {
            let urls = appState.discoveredFiles
            let task = Task.detached(priority: .utility) {
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
        .disabled(!appState.canBeginAppRemoval)

    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.appName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([app.path])
                } label: {
                    Label((app.path.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Scanning for related files...").font(.headline)
            Text(checkingLocationsText(count: appState.currentAppFileSearchLocationCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouped list

    private var fileGroupsList: some View {
        List {
            ForEach(groupedFiles, id: \.group) { entry in
                DisclosureGroup(isExpanded: groupExpansionBinding(entry.group)) {
                    // No .staggered() inside the lazy List — a delayed reveal
                    // would blank rows as they scroll in. The removal
                    // transition still sweeps deleted rows out.
                    ForEach(entry.urls, id: \.self) { fileURL in
                        FileRow(
                            fileURL: fileURL,
                            isSelected: fileSelectionBinding(for: fileURL),
                            fileSize: cachedSize(fileURL),
                            onRemove: { appState.reviewSelectedAppFiles([fileURL]) }
                        )
                        .transition(
                            !motionEnabled
                                ? .identity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                } label: {
                    groupHeader(entry.group, urls: entry.urls)
                }
            }
        }
        .id(app.id)
    }

    private func groupHeader(_ group: LeftoverGroup, urls: [URL]) -> some View {
        let groupSize = urls.reduce(Int64(0)) { $0 + (cachedSize($1) ?? 0) }
        let allSelected = urls.allSatisfy { appState.selectedFiles.contains($0) }

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { selected in
                    if selected {
                        appState.selectedFiles.formUnion(urls)
                    } else {
                        appState.selectedFiles.subtract(urls)
                    }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(LocalizedStringKey(group.rawValue)))

            Text(LocalizedStringKey(group.rawValue))
                .font(.subheadline.weight(.semibold))
            Text(urls.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if urls.allSatisfy({ sizeCache[$0] != nil }) {
                Text(ByteCountFormatter.string(fromByteCount: groupSize, countStyle: .file))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func groupExpansionBinding(_ group: LeftoverGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group) },
            set: { expanded in
                let change = {
                    if expanded {
                        collapsedGroups.remove(group)
                    } else {
                        collapsedGroups.insert(group)
                    }
                }
                if !motionEnabled {
                    change()
                } else {
                    withAnimation(.easeOut(duration: 0.16)) { change() }
                }
            }
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        let selected = appState.selectedFiles.count
        let all = appState.discoveredFiles.count
        let sizesReady = selected > 0 && appState.selectedFiles.allSatisfy { sizeCache[$0] != nil }
        let selectedSize = sizesReady ? ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file) : nil
        let summary = HStack(spacing: 6) {
            Text("\(selected) of \(all) selected")
            if let selectedSize {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(selectedSize)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                selectionControl(allSelected: selected == all)
                summary
                Spacer(minLength: 4)
                reviewButton
            }
            VStack(alignment: .leading, spacing: 6) {
                summary
                HStack { selectionControl(allSelected: selected == all); Spacer(); reviewButton }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func selectionControl(allSelected: Bool) -> some View {
        Menu {
            Button("Select All") { appState.selectedFiles = Set(appState.discoveredFiles) }
                .disabled(allSelected)
            Button("Deselect All") { appState.selectedFiles.removeAll() }
                .disabled(appState.selectedFiles.isEmpty)
        } label: {
            Label("Select", systemImage: "checklist")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var reviewButton: some View {
        Button {
            appState.reviewSelectedAppFiles(appState.selectedFiles)
        } label: {
            Text("Review Selected Files")
        }
        .buttonStyle(.borderedProminent)
        .disabled(appState.selectedFiles.isEmpty)
    }

    private func checkingLocationsText(count: Int) -> String {
        String(format: String(localized: "Checking %lld locations..."), Int64(count))
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

    private func cachedSize(_ url: URL) -> Int64? {
        sizeCache[url]
    }
}

struct FileRow: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onRemove: () -> Void
    var onReveal: (() -> Void)? = nil

    var body: some View {
        HStack {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: fileURL.lastPathComponent))
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL.lastPathComponent)
                    .lineLimit(1)
                    .accessibilityIdentifier("apps.fileName.\(fileURL.lastPathComponent)")
                Text((fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fileURL.path)
                    .accessibilityLabel(Text(verbatim: fileURL.path))
            }
            .contentShape(Rectangle())
            .onTapGesture { isSelected.toggle() }
            Spacer()
            if let size = fileSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                if let onReveal { onReveal() } else { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            Button(action: onRemove) {
                Label("Review this file", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .help("Review this file")
            .accessibilityIdentifier("apps.fileReview.\(fileURL.lastPathComponent)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }
}
