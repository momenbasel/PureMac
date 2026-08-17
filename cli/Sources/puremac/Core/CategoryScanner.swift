import Foundation

enum CategoryScanner {
    static let minSize: Int64 = 1024

    static func scan(categoryID id: String, title: String, ignore: IgnoreStore) -> CategoryScan {
        FileHandle.standardError.write(Data("  scanning \(title)…\r".utf8))
        let groups = id == "trash" ? scanTrash(ignore: ignore) : scanCatalog(id: id, ignore: ignore)
        FileHandle.standardError.write(Data("                                        \r".utf8))
        return CategoryScan(id: id, title: title, groups: groups)
    }

    private static func scanCatalog(id: String, ignore: IgnoreStore) -> [ToolGroup] {
        let targets = Catalog.targets(for: id)
        var candidates: [(target: Int, path: String)] = []
        for (ti, target) in targets.enumerated() {
            let paths = target.contents
                ? target.paths.filter { !Safety.isSymlink($0) }.flatMap(children(of:))
                : target.paths
            for path in paths where passesPreFilter(path, ignore: ignore) {
                candidates.append((ti, path))
            }
        }
        let sizes = concurrentSizes(candidates.map { $0.path })

        var itemsByTarget = [Int: [ScanItem]](minimumCapacity: targets.count)
        for (i, c) in candidates.enumerated() where sizes[i] >= minSize {
            let item = ScanItem(path: c.path, sizeBytes: sizes[i],
                                modified: DirSizer.modified(of: c.path),
                                selected: targets[c.target].selectedByDefault)
            itemsByTarget[c.target, default: []].append(item)
        }
        return targets.indices.compactMap { ti in
            guard let items = itemsByTarget[ti], !items.isEmpty else { return nil }
            return ToolGroup(tool: targets[ti].tool, items: items)
        }
    }

    private static func children(of dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { "\(dir)/\($0)" }
    }

    private static func passesPreFilter(_ path: String, ignore: IgnoreStore) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        if let type = (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType, type == .typeSymbolicLink {
            return false
        }
        if Safety.isProviderOwned(path) { return false }
        if ignore.isIgnored(path) { return false }
        return true
    }

    static func concurrentSizes(_ paths: [String]) -> [Int64] {
        guard !paths.isEmpty else { return [] }
        var out = [Int64](repeating: 0, count: paths.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                buf[i] = DirSizer.size(of: paths[i])
            }
        }
        return out
    }

    private static func scanTrash(ignore: IgnoreStore) -> [ToolGroup] {
        let fm = FileManager.default
        var roots = ["\(Safety.home)/.Trash"]
        let uid = getuid()
        if let vols = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for vol in vols { roots.append("/Volumes/\(vol)/.Trashes/\(uid)") }
        }

        var groups: [ToolGroup] = []
        for root in roots where !Safety.isSymlink(root) {
            guard let children = try? fm.contentsOfDirectory(atPath: root), !children.isEmpty else { continue }
            let paths = children.map { "\(root)/\($0)" }.filter { passesPreFilter($0, ignore: ignore) }
            let sizes = concurrentSizes(paths)
            let items = zip(paths, sizes).compactMap { (path, size) -> ScanItem? in
                size >= minSize ? ScanItem(path: path, sizeBytes: size, modified: DirSizer.modified(of: path)) : nil
            }
            if !items.isEmpty {
                let label = root.hasPrefix("/Volumes/")
                    ? "Trash — \(URL(fileURLWithPath: root).deletingLastPathComponent().lastPathComponent)"
                    : "Trash"
                groups.append(ToolGroup(tool: label, items: items))
            }
        }
        return groups
    }
}
