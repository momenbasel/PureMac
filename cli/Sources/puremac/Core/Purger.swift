import Foundation

enum Purger {

    static let artifactNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".svelte-kit", ".angular", ".parcel-cache",
        "target", ".build", "DerivedData", "Pods",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".ruff_cache",
        ".gradle",
    ]

    static let artifactPrefixes = ["cmake-build"]

    static let defaultRoots = ["Projects", "Code", "dev", "GitHub", "Workspace"]
        .map { "\(Safety.home)/\($0)" }

    static func isArtifact(_ name: String) -> Bool {
        artifactNames.contains(name) || artifactPrefixes.contains { name.hasPrefix($0) }
    }

    static func scan(
        roots: [String],
        olderThanDays: Int,
        ignore: IgnoreStore,
        progress: ((PurgeScanEvent) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> CategoryScan {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        var byProject: [String: [ScanItem]] = [:]
        var order: [String] = []

        walk: for rootURL in scanRoots(roots) {
            progress?(.root(rootURL.path))
            guard let en = fm.enumerator(at: rootURL,
                                         includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [.skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }

            for case let url as URL in en {
                if isCancelled() { break walk }
                let name = url.lastPathComponent
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { en.skipDescendants(); continue }
                guard vals?.isDirectory == true else { continue }
                if en.level > 8 { en.skipDescendants(); continue }
                if Safety.isCloudOrDataless(url.path) || Safety.isPathIgnored(url.path, ignore: ignore) {
                    en.skipDescendants()
                    continue
                }

                progress?(.walking(url.path))

                if isArtifact(name) {
                    en.skipDescendants()
                    if Safety.ignoredPathProtectsCandidate(url.path, ignore: ignore) { continue }
                    let measurement = DirSizer.measure(of: url.path, isCancelled: isCancelled)
                    guard measurement.status == .complete,
                          measurement.bytes >= CategoryScanner.minSize else { continue }
                    let mod = DirSizer.modified(of: url.path)
                    let old = (mod ?? .distantFuture) < cutoff
                    let project = projectLabel(url, level: en.level, root: rootURL)
                    let item = ScanItem(path: url.path, sizeBytes: measurement.bytes, modified: mod, selected: old)
                    progress?(.found(bytes: measurement.bytes))
                    byProject[project, default: []].append(item)
                    if !order.contains(project) { order.append(project) }
                }
            }
        }

        let groups = order.map { proj in
            ToolGroup(tool: proj, items: byProject[proj]!.sorted { $0.sizeBytes > $1.sizeBytes })
        }.sorted { $0.allBytes > $1.allBytes }
        return CategoryScan(id: "purge", title: "Project Artifacts", groups: groups)
    }

    static func scanRoots(_ roots: [String]) -> [URL] {
        let candidates = roots.compactMap { root -> URL? in
            guard Safety.isValidScanRoot(root).ok else { return nil }
            return URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        }.sorted { $0.path.count < $1.path.count }
        var accepted: [URL] = []
        for candidate in candidates where !accepted.contains(where: {
            candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/")
        }) {
            accepted.append(candidate)
        }
        return accepted
    }

    private static func projectLabel(_ url: URL, level: Int, root: URL) -> String {
        guard level > 1 else { return url.lastPathComponent }
        var u = url
        for _ in 0..<(level - 1) { u = u.deletingLastPathComponent() }
        return u.lastPathComponent
    }
}
