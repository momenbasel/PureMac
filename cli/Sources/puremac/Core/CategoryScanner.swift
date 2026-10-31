import Foundation

enum ScanProgress: Equatable {
    case stderr, silent

    static func forMode(_ mode: CleanupCommandMode) -> ScanProgress {
        mode == .fullscreen ? .silent : .stderr
    }

    func write(_ text: String) {
        guard self == .stderr else { return }
        FileHandle.standardError.write(Data(text.utf8))
    }
}

enum CategoryScanner {
    static let minSize: Int64 = 1024

    static func scan(
        categoryID id: String,
        title: String,
        ignore: IgnoreStore,
        progress: ScanProgress = .stderr,
        isCancelled: () -> Bool = { false }
    ) -> CategoryScan {
        progress.write("  scanning \(title)…\r")
        let groups = id == "trash"
            ? scanTrash(roots: trashRoots(), ignore: ignore, isCancelled: isCancelled)
            : scanCatalog(targets: Catalog.targets(for: id), ignore: ignore, isCancelled: isCancelled)
        progress.write("                                        \r")
        return CategoryScan(id: id, title: title, groups: groups)
    }

    static func scanCatalog(targets: [Target], ignore: IgnoreStore, isCancelled: () -> Bool) -> [ToolGroup] {
        var candidates: [(target: Int, path: String)] = []
        for (ti, target) in targets.enumerated() {
            let paths = target.contents
                ? target.paths.filter {
                    !Safety.hasSymlinkComponent($0)
                        && !Safety.isCloudOrDataless($0)
                        && !Safety.isPathIgnored($0, ignore: ignore)
                }.flatMap(children(of:))
                : target.paths
            for path in paths where passesPreFilter(path, ignore: ignore) {
                candidates.append((ti, path))
            }
        }
        candidates = uniqueCandidates(candidates)
        if isCancelled() { return [] }
        let measurements = concurrentMeasurements(candidates.map { $0.path }, isCancelled: isCancelled)

        var itemsByTarget = [Int: [ScanItem]](minimumCapacity: targets.count)
        for (i, c) in candidates.enumerated()
            where measurements[i].status == .complete && measurements[i].bytes >= minSize {
            let item = ScanItem(path: c.path, sizeBytes: measurements[i].bytes,
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
        if Safety.hasSymlinkComponent(path) { return false }
        if Safety.isCloudOrDataless(path) { return false }
        if Safety.ignoredPathProtectsCandidate(path, ignore: ignore) { return false }
        return true
    }

    static func concurrentSizes(_ paths: [String]) -> [Int64] {
        concurrentMeasurements(paths).map(\.bytes)
    }

    static func concurrentMeasurements(_ paths: [String], isCancelled: () -> Bool = { false }) -> [DirSizer.Measurement] {
        guard !paths.isEmpty else { return [] }
        var out = [DirSizer.Measurement](
            repeating: DirSizer.Measurement(bytes: 0, status: .unavailable, skippedEntries: 1),
            count: paths.count
        )
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                buf[i] = DirSizer.measure(of: paths[i], isCancelled: isCancelled)
            }
        }
        return out
    }

    static func uniqueCandidates(_ candidates: [(target: Int, path: String)]) -> [(target: Int, path: String)] {
        var seenPaths: Set<String> = []
        var seenIdentities: Set<FileIdentity> = []
        var accepted: [(target: Int, path: String, canonical: String)] = []
        let ordered = candidates.enumerated().sorted {
            if $0.element.path.count != $1.element.path.count {
                return $0.element.path.count < $1.element.path.count
            }
            return $0.offset < $1.offset
        }.map(\.element)
        for candidate in ordered {
            let canonical = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard !accepted.contains(where: {
                canonical == $0.canonical || canonical.hasPrefix($0.canonical + "/")
            }) else { continue }
            guard seenPaths.insert(canonical).inserted else { continue }
            if let identity = Safety.fileIdentity(at: canonical), !seenIdentities.insert(identity).inserted {
                continue
            }
            accepted.append((candidate.target, candidate.path, canonical))
        }
        return accepted.map { ($0.target, $0.path) }
    }

    private static func trashRoots() -> [String] {
        var roots = ["\(Safety.home)/.Trash"]
        let uid = getuid()
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in vols { roots.append("/Volumes/\(vol)/.Trashes/\(uid)") }
        }
        return roots
    }

    static func scanTrash(roots: [String], ignore: IgnoreStore, isCancelled: () -> Bool) -> [ToolGroup] {
        let fm = FileManager.default
        var groups: [ToolGroup] = []
        for root in roots where !Safety.hasSymlinkComponent(root) && !Safety.isCloudOrDataless(root) {
            if isCancelled() { break }
            guard let children = try? fm.contentsOfDirectory(atPath: root), !children.isEmpty else { continue }
            let paths = children.map { "\(root)/\($0)" }.filter { passesPreFilter($0, ignore: ignore) }
            let unique = uniqueCandidates(paths.map { (target: 0, path: $0) })
            let measurements = concurrentMeasurements(unique.map(\.path), isCancelled: isCancelled)
            let items = zip(unique.map(\.path), measurements).compactMap { (path, measurement) -> ScanItem? in
                measurement.status == .complete && measurement.bytes >= minSize
                    ? ScanItem(path: path, sizeBytes: measurement.bytes, modified: DirSizer.modified(of: path))
                    : nil
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
