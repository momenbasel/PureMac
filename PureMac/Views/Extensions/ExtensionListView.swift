import SwiftUI

private enum ExtensionLeftoverGroup: String, CaseIterable, Identifiable {
    case extensionInstall = "Extension"
    case globalStorage = "Global Storage"
    case workspaceStorage = "Workspace Storage"
    case vsixCache = "VSIX Cache"
    case homePersonalization = "Home Personalization"
    case other = "Other Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .extensionInstall: return "puzzlepiece.extension"
        case .globalStorage: return "externaldrive.fill"
        case .workspaceStorage: return "folder.fill"
        case .vsixCache: return "shippingbox.fill"
        case .homePersonalization: return "house.fill"
        case .other: return "doc.fill"
        }
    }

    static func categorize(_ url: URL) -> ExtensionLeftoverGroup {
        let path = url.path
        if path.contains("/CachedExtensionVSIXs/") { return .vsixCache }
        if path.contains("/globalStorage/") { return .globalStorage }
        if path.contains("/workspaceStorage/") { return .workspaceStorage }
        if path.contains("/extensions/") { return .extensionInstall }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if VSCodeExtensionHomePathRules.isHomePersonalizationPath(url, homeDirectory: home) {
            return .homePersonalization
        }
        return .other
    }
}

struct ExtensionListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: VSCodeExtensionItem.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sortOrder: [KeyPathComparator<VSCodeExtensionItem>] = [
        .init(\.size, order: .reverse)
    ]

    private var filtered: [VSCodeExtensionItem] {
        let base: [VSCodeExtensionItem]
        if searchText.isEmpty {
            base = appState.vscodeExtensions
        } else {
            let q = searchText.lowercased()
            base = appState.vscodeExtensions.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.extensionId.lowercased().contains(q)
                    || $0.editorLabel.lowercased().contains(q)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            extensionTable
                .frame(minWidth: 320, idealWidth: 420, maxWidth: 640)
            fileDetail
                .frame(minWidth: 300)
        }
        .searchable(text: $searchText, prompt: Text(LocalizedStringKey("Search extensions")))
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadVSCodeExtensions()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button(removeLabel, role: .destructive) {
                    // Pass current table order so "next" matches what the user sees.
                    appState.removeSelectedExtensionRelatedFiles(displayOrder: filtered)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .opacity(appState.selectedExtensionRelatedFiles.isEmpty ? 0 : 1)
                .disabled(appState.selectedExtensionRelatedFiles.isEmpty)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                    value: appState.selectedExtensionRelatedFiles.isEmpty
                )
            }
        }
        .onAppear {
            if appState.vscodeExtensions.isEmpty && !appState.isLoadingVSCodeExtensions {
                appState.loadVSCodeExtensions()
            }
        }
    }

    private var title: String {
        String(
            format: String(localized: "VS Code Extensions (%lld)"),
            Int64(appState.vscodeExtensions.count)
        )
    }

    private var removeLabel: String {
        String(
            format: String(localized: "Remove (%lld files)"),
            Int64(appState.selectedExtensionRelatedFiles.count)
        )
    }

    private var extensionTable: some View {
        Group {
            if appState.isLoadingVSCodeExtensions {
                ProgressView(LocalizedStringKey("Loading extensions..."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.vscodeExtensions.isEmpty {
                EmptyStateView(
                    "No Extensions Found",
                    systemImage: "puzzlepiece.extension",
                    description: "No VS Code–family extensions with engines.vscode were found under ~/.*/extensions.",
                    action: { appState.loadVSCodeExtensions() },
                    actionLabel: "Retry"
                )
            } else {
                Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Extension", value: \.displayName) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                            Text(item.extensionId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 160)
                    TableColumn("Editor", value: \.editorLabel) { item in
                        Text(item.editorLabel)
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 100)
                    TableColumn("Size", value: \.size) { item in
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 80)
                }
                .onChange(of: selection) { newValue in
                    guard let id = newValue,
                          let item = appState.vscodeExtensions.first(where: { $0.id == id })
                    else { return }
                    guard appState.selectedVSCodeExtension?.id != item.id else { return }
                    appState.scanExtensionRelatedFiles(item)
                }
                .onChange(of: appState.selectedVSCodeExtension) { item in
                    if selection != item?.id { selection = item?.id }
                }
                .onChange(of: appState.vscodeExtensions) { items in
                    if let id = selection, !items.contains(where: { $0.id == id }) {
                        // Prefer AppState's advanced selection (next/previous) over clearing.
                        selection = appState.selectedVSCodeExtension?.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fileDetail: some View {
        if let item = appState.selectedVSCodeExtension {
            ExtensionFilesView(item: item)
        } else {
            EmptyStateView(
                "Select an Extension",
                systemImage: "cursorarrow.click.2",
                description: "Select an extension to review its install folder and related storage/cache files.",
                tint: Tint.purple
            )
        }
    }
}

struct ExtensionFilesView: View {
    @EnvironmentObject var appState: AppState
    let item: VSCodeExtensionItem
    @State private var collapsed: Set<ExtensionLeftoverGroup> = []
    @State private var sizeCache: [URL: Int64] = [:]

    private var grouped: [(ExtensionLeftoverGroup, [URL])] {
        let buckets = Dictionary(grouping: appState.extensionRelatedFiles, by: ExtensionLeftoverGroup.categorize)
        return ExtensionLeftoverGroup.allCases.compactMap { group in
            guard let urls = buckets[group], !urls.isEmpty else { return nil }
            return (group, urls)
        }
    }

    private var selectedTotalSize: Int64 {
        appState.selectedExtensionRelatedFiles.reduce(Int64(0)) { total, url in
            total + (sizeCache[url] ?? FileSizeCalculator.size(of: url) ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.isScanningExtensionRelatedFiles {
                ProgressView(LocalizedStringKey("Scanning related files..."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.extensionRelatedFiles.isEmpty {
                EmptyStateView(
                    "No Related Files",
                    systemImage: "checkmark.circle",
                    description: "Only the install directory was expected; nothing else matched for this extension."
                )
            } else {
                List {
                    ForEach(grouped, id: \.0.id) { group, urls in
                        Section {
                            if !collapsed.contains(group) {
                                ForEach(urls, id: \.path) { url in
                                    row(url)
                                }
                            }
                        } header: {
                            HStack {
                                Label(LocalizedStringKey(group.rawValue), systemImage: group.icon)
                                Spacer()
                                Text(groupSizeText(urls))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text("\(urls.count)")
                                    .foregroundStyle(.secondary)
                                Button {
                                    if collapsed.contains(group) {
                                        collapsed.remove(group)
                                    } else {
                                        collapsed.insert(group)
                                    }
                                } label: {
                                    Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { rebuildSizeCache() }
        .onChange(of: appState.extensionRelatedFiles) { _ in rebuildSizeCache() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayName)
                .font(.title2.weight(.semibold))
            Text("\(item.editorLabel) · \(item.extensionId)")
                .foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Select All")) {
                    appState.selectedExtensionRelatedFiles = Set(appState.extensionRelatedFiles)
                }
                Button(String(localized: "Select None")) {
                    appState.selectedExtensionRelatedFiles = []
                }
                Spacer()
                Text(selectedSummaryText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private var selectedSummaryText: String {
        let count = "\(appState.selectedExtensionRelatedFiles.count)/\(appState.extensionRelatedFiles.count)"
        let size = ByteCountFormatter.string(fromByteCount: selectedTotalSize, countStyle: .file)
        return "\(count) · \(size)"
    }

    private func groupSizeText(_ urls: [URL]) -> String {
        let total = urls.reduce(Int64(0)) { partial, url in
            partial + (sizeCache[url] ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func row(_ url: URL) -> some View {
        let selected = appState.selectedExtensionRelatedFiles.contains(url)
        let size = sizeCache[url] ?? 0
        return Toggle(isOn: Binding(
            get: { selected },
            set: { on in
                if on {
                    appState.selectedExtensionRelatedFiles.insert(url)
                } else {
                    appState.selectedExtensionRelatedFiles.remove(url)
                }
            }
        )) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func rebuildSizeCache() {
        var cache: [URL: Int64] = [:]
        for url in appState.extensionRelatedFiles {
            cache[url] = FileSizeCalculator.size(of: url) ?? 0
        }
        sizeCache = cache
    }
}
