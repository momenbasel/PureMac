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

    static func scan(roots: [String], olderThanDays: Int, ignore: IgnoreStore) -> CategoryScan {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        var byProject: [String: [ScanItem]] = [:]
        var order: [String] = []

        for root in roots where Safety.isValidScanRoot(root).ok {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let en = fm.enumerator(at: rootURL,
                                         includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [.skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }

            for case let url as URL in en {
                let name = url.lastPathComponent
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { en.skipDescendants(); continue }
                guard vals?.isDirectory == true else { continue }
                if en.level > 8 { en.skipDescendants(); continue }
                if Safety.isProviderOwned(url.path) || ignore.isIgnored(url.path) { en.skipDescendants(); continue }

                if isArtifact(name) {
                    en.skipDescendants()
                    let size = DirSizer.size(of: url.path)
                    guard size >= CategoryScanner.minSize else { continue }
                    let mod = DirSizer.modified(of: url.path)
                    let old = (mod ?? .distantFuture) < cutoff
                    let project = projectLabel(url, level: en.level, root: rootURL)
                    let item = ScanItem(path: url.path, sizeBytes: size, modified: mod, selected: old)
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

    private static func projectLabel(_ url: URL, level: Int, root: URL) -> String {
        guard level > 1 else { return url.lastPathComponent }
        var u = url
        for _ in 0..<(level - 1) { u = u.deletingLastPathComponent() }
        return u.lastPathComponent
    }
}
