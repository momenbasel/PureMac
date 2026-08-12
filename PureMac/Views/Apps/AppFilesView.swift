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

    var icon: String {
        switch self {
        case .application: return "app.fill"
        case .caches: return "internaldrive.fill"
        case .appSupport: return "shippingbox.fill"
        case .preferences: return "gearshape.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "cube.box.fill"
        case .launchAgents: return "bolt.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .application: return Tint.blue
        case .caches: return Tint.orange
        case .appSupport: return Tint.purple
        case .preferences: return Tint.cyan
        case .logs: return Tint.yellow
        case .containers: return Tint.pink
        case .launchAgents: return Tint.red
        case .other: return Tint.green
        }
    }

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
    @State private var iconHovering = false
    /// One-pass size cache so group headers and the selected-size counter
    /// don't re-stat the disk on every render.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

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
        .onAppear { rebuildSizeCache() }
        .onChange(of: appState.discoveredFiles) { _ in rebuildSizeCache() }
        .onChange(of: appState.removalNeedsFullDiskAccess) { needs in
            // FDA-fixable removals jump straight into the rich sheet, the
            // same flow cleanup uses. The user grants permission once and we
            // re-fire the failed batch — using the frozen snapshot from
            // AppState so a mid-sheet selection change or app switch doesn't
            // re-trash the wrong files.
            guard needs else { return }
            let toRetry = appState.lastFailedRemovalURLs
            let items = toRetry.map { appState.makeUninstallCleanableItem(for: $0) }
            appState.removalError = nil
            appState.removalNeedsFullDiskAccess = false
            appState.lastFailedRemovalURLs = []
            appState.requestFullDiskAccessAndRetry(
                items: items,
                context: .uninstall(appName: app.appName, failedCount: items.count)
            )
        }
        .alert("Removal Failed", isPresented: Binding(
            get: { appState.removalError != nil && !appState.removalNeedsFullDiskAccess },
            set: {
                if !$0 {
                    appState.removalError = nil
                    appState.removalNeedsFullDiskAccess = false
                }
            }
        )) {
            Button("OK", role: .cancel) {
                appState.removalError = nil
                appState.removalNeedsFullDiskAccess = false
            }
        } message: {
            Text(appState.removalError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        CardSurface(padding: 16, tint: Tint.purple) {
            HStack(spacing: 14) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .scaleEffect(iconHovering && !reduceMotion ? 1.06 : 1)
                    .animation(reduceMotion ? nil : MotionTokens.snappy, value: iconHovering)
                    .onHover { iconHovering = $0 }

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.appName)
                        .font(.system(size: 17, weight: .bold))
                    Text(app.bundleIdentifier)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !appState.discoveredFiles.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        CountUpBytes(bytes: totalSelectedSize)
                            .font(.system(size: 18, weight: .bold))
                        Text(filesCountText(count: appState.discoveredFiles.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9),
                               value: appState.discoveredFiles.count)
                }
            }
        }
    }

    // MARK: - Scanning state

    private var scanningState: some View {
        VStack(spacing: 14) {
            Spacer()
            if reduceMotion {
                ProgressView(LocalizedStringKey("Scanning for related files..."))
            } else {
                SearchPulse()
                Text("Scanning for related files...")
                    .font(.system(size: 13, weight: .medium))
            }
            Text(checkingLocationsText(count: appState.currentAppFileSearchLocationCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
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
                            onRemove: { removeSingleFile(fileURL) }
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
            .toggleStyle(AnimatedCheckboxStyle())
            .labelsHidden()

            IconTile(systemName: group.icon, tint: group.tint, size: 22, corner: 6)
            Text(LocalizedStringKey(group.rawValue))
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(urls.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: groupSize, countStyle: .file))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                if reduceMotion {
                    change()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { change() }
                }
            }
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Select All") {
                appState.selectedFiles = Set(appState.discoveredFiles)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Deselect All") {
                appState.selectedFiles.removeAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if !appState.selectedFiles.isEmpty {
                Button(role: .destructive) {
                    appState.removeSelectedFiles()
                } label: {
                    Text(removeFilesLabel)
                }
                .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: appState.selectedFiles.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    // MARK: - Helpers

    private func filesCountText(count: Int) -> String {
        String(format: String(localized: "%lld files"), Int64(count))
    }

    private func checkingLocationsText(count: Int) -> String {
        String(format: String(localized: "Checking %lld locations..."), Int64(count))
    }

    private var removeFilesLabel: String {
        String(
            format: String(localized: "Remove %lld files (%@)"),
            Int64(appState.selectedFiles.count),
            ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
        )
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
        if let cached = sizeCache[url] { return cached }
        return fileSize(url)
    }

    private func rebuildSizeCache() {
        var cache: [URL: Int64] = [:]
        for url in appState.discoveredFiles {
            cache[url] = fileSize(url) ?? 0
        }
        sizeCache = cache
    }

    private func fileSize(_ url: URL) -> Int64? {
        FileSizeCalculator.size(of: url)
    }

    private func removeSingleFile(_ url: URL) {
        appState.selectedFiles = [url]
        appState.removeSelectedFiles()
    }
}

/// Magnifier over expanding sonar rings — the "actively searching" beat for
/// the related-files scan. Only built when Reduce Motion is off.
private struct SearchPulse: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Tint.blue.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.7),
                        value: pulse
                    )
            }
            Circle()
                .fill(Tint.blue.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tint.blue)
        }
        .frame(width: 56, height: 56)
        .onAppear { pulse = true }
    }
}

// MARK: - File Row with hover-to-reveal actions

struct FileRow: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var showConfirmation = false
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

                // Buttons stay in the layout permanently and fade with
                // hover, so the trailing size badge never jumps sideways.
                Button {
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                Button {
                    showConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this file")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle())
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isHovering)
        .onHover { isHovering = $0 }
        .alert(
            Text(
                String(format: String(localized: "Remove %@?"), fileURL.lastPathComponent)
            ),
            isPresented: $showConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This will permanently delete this file. This action cannot be undone.")
        }
    }
}
