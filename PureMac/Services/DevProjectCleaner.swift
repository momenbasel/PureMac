import Darwin
import Foundation

struct DevProjectFileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct DevProjectItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case artifact
        case worktree
        case orphanedWorktree
    }

    let url: URL
    let kind: Kind
    let project: String
    let size: Int64
    let modified: Date?
    /// Why the item is not preselected (nil when it is).
    let note: String?
    let preselected: Bool
    var fileID: DevProjectFileID?

    var id: URL { url }

    init(
        url: URL,
        kind: Kind,
        project: String,
        size: Int64,
        modified: Date?,
        note: String?,
        preselected: Bool,
        fileID: DevProjectFileID? = nil
    ) {
        self.url = url
        self.kind = kind
        self.project = project
        self.size = size
        self.modified = modified
        self.note = note
        self.preselected = preselected
        self.fileID = fileID
    }
}

struct DevProjectScanResult: Sendable {
    let folder: URL
    let items: [DevProjectItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct DevProjectRemovalOutcome: Sendable {
    var removed = 0
    var freedBytes: Int64 = 0
    var skipped: [(path: String, reason: String)] = []
    var failed: [(path: String, error: String)] = []
}

/// Finds and removes developer build artifacts (node_modules, .turbo, …) and
/// linked git worktrees under a folder. Worktrees are removed with
/// `git worktree remove` (never `--force`), so git refuses anything with
/// uncommitted changes or a lock.
enum DevProjectCleaner {
    static let artifactNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".svelte-kit", ".angular", ".parcel-cache",
        "target", ".build", "DerivedData", "Pods",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".ruff_cache",
        ".gradle",
    ]
    static let artifactPrefixes = ["cmake-build"]
    static let minimumArtifactSize: Int64 = 1_024
    private static let maxDepth = 8

    static func isArtifact(_ name: String) -> Bool {
        artifactNames.contains(name) || artifactPrefixes.contains { name.hasPrefix($0) }
    }

    /// `~/.supacode`, when present, so Supacode-managed worktrees are included.
    static var supacodeRoots: [URL] {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.supacode", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
    }

    // MARK: - Scan

    static func scan(
        folder: URL,
        extraRoots: [URL] = [],
        olderThanDays: Int,
        excludedPaths: [String]
    ) -> DevProjectScanResult {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        let roots = ([folder] + extraRoots).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let allowedPrefixes = roots.map(\.path)
        let primary = roots[0]

        var artifacts: [DevProjectItem] = []
        var orphanPaths: [String] = []
        var commonDirs = Set<String>()

        func insideExcluded(_ path: String) -> Bool {
            excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        for root in roots {
            if Task.isCancelled { break }
            note(root.path, classify: &commonDirs, orphans: &orphanPaths)
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let rawURL as URL in en {
                if Task.isCancelled { break }
                let url = rawURL.resolvingSymlinksInPath()
                let vals = try? rawURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { en.skipDescendants(); continue }
                guard vals?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                if name == ".git" || en.level > maxDepth { en.skipDescendants(); continue }
                if isCloudPath(url.path) || insideExcluded(url.path) { en.skipDescendants(); continue }

                if isArtifact(name) {
                    en.skipDescendants()
                    if CleanupExclusions.excludes(url.path, paths: excludedPaths) { continue }
                    guard let size = FileSizeCalculator.size(of: url), size >= minimumArtifactSize else { continue }
                    let modified = modifiedDate(url)
                    let old = (modified ?? .distantFuture) <= cutoff
                    artifacts.append(DevProjectItem(
                        url: url, kind: .artifact,
                        project: projectName(for: url, under: root, fallback: primary),
                        size: size, modified: modified,
                        note: old ? nil : "recent", preselected: old,
                        fileID: fileID(url.path)
                    ))
                    continue
                }
                if note(url.path, classify: &commonDirs, orphans: &orphanPaths) == .orphaned {
                    en.skipDescendants()
                }
            }
        }

        var items = artifacts
        var seen = Set<String>()

        for common in commonDirs.sorted() where !Task.isCancelled {
            let list = Git.run(["--git-dir=\(common)", "worktree", "list", "--porcelain"])
            guard list.status == 0 else { continue }
            let repoDir = (common as NSString).lastPathComponent == ".git"
                ? (common as NSString).deletingLastPathComponent : common
            let repoName = (repoDir as NSString).lastPathComponent
            for entry in DevWorktreeEntry.parse(list.out) where !entry.isMain && !entry.prunable {
                guard allowedPrefixes.contains(where: { entry.path.hasPrefix($0 + "/") }),
                      !insideExcluded(entry.path),
                      !CleanupExclusions.excludes(entry.path, paths: excludedPaths),
                      seen.insert(entry.path).inserted else { continue }
                items.append(worktreeItem(entry, project: repoName, cutoff: cutoff, artifacts: artifacts))
            }
        }

        for path in Set(orphanPaths).sorted() where !seen.contains(path) && !Task.isCancelled {
            if insideExcluded(path) || CleanupExclusions.excludes(path, paths: excludedPaths) { continue }
            let url = URL(fileURLWithPath: path)
            let nested = artifacts.filter { $0.url.path.hasPrefix(path + "/") }.reduce(Int64(0)) { $0 + $1.size }
            items.append(DevProjectItem(
                url: url, kind: .orphanedWorktree, project: "Orphaned worktrees",
                size: max(0, (FileSizeCalculator.size(of: url) ?? 0) - nested),
                modified: modifiedDate(url), note: "orphaned: repository missing", preselected: false,
                fileID: fileID(path)
            ))
        }

        items.sort { ($0.project, $1.size) < ($1.project, $0.size) }
        return DevProjectScanResult(folder: folder, items: items)
    }

    @discardableResult
    private static func note(
        _ dir: String,
        classify commonDirs: inout Set<String>,
        orphans: inout [String]
    ) -> DevWorktreeLink {
        let link = DevWorktreeLink.classify(dir)
        switch link {
        case .mainCheckout:
            commonDirs.insert(URL(fileURLWithPath: dir + "/.git").resolvingSymlinksInPath().path)
        case .linked(let common):
            commonDirs.insert(common)
        case .orphaned:
            orphans.append(URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
        case .none:
            break
        }
        return link
    }

    private static func worktreeItem(
        _ entry: DevWorktreeEntry,
        project: String,
        cutoff: Date,
        artifacts: [DevProjectItem]
    ) -> DevProjectItem {
        let url = URL(fileURLWithPath: entry.path)
        let nested = artifacts.filter { $0.url.path.hasPrefix(entry.path + "/") }.reduce(Int64(0)) { $0 + $1.size }
        let size = max(0, (FileSizeCalculator.size(of: url) ?? 0) - nested)

        var commitDate: Date?
        let log = Git.run(["-C", entry.path, "log", "-1", "--format=%ct"])
        if log.status == 0, let secs = TimeInterval(log.out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            commitDate = Date(timeIntervalSince1970: secs)
        }
        let modified = commitDate ?? modifiedDate(url)

        let note: String?
        if entry.locked {
            note = "locked"
        } else {
            let status = Git.run(["-C", entry.path, "status", "--porcelain"])
            if status.status != 0 {
                note = "git status failed"
            } else if !status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note = "uncommitted changes"
            } else if Git.unpushedCount(at: entry.path, includeBranches: false) != 0 {
                note = "unpushed commits"
            } else if let modified, modified > cutoff {
                note = "recent"
            } else {
                note = nil
            }
        }
        return DevProjectItem(
            url: url, kind: .worktree, project: project, size: size, modified: modified,
            note: note, preselected: note == nil, fileID: fileID(entry.path)
        )
    }

    // MARK: - Removal

    static func remove(_ items: [DevProjectItem], excludedPaths: [String]) -> DevProjectRemovalOutcome {
        var out = DevProjectRemovalOutcome()
        var touched = Set<String>()
        let fm = FileManager.default

        // Artifacts first so artifacts nested in a worktree are not counted twice.
        let ordered = items.filter { $0.kind == .artifact } + items.filter { $0.kind != .artifact }
        for item in ordered {
            if Task.isCancelled { break }
            let path = item.url.path
            if let reason = unsafeReason(path, excludedPaths: excludedPaths) {
                out.skipped.append((path, reason)); continue
            }
            if let expected = item.fileID, fileID(path) != expected {
                out.skipped.append((path, "changed since scan")); continue
            }
            let size = FileSizeCalculator.size(of: item.url) ?? 0

            switch item.kind {
            case .artifact:
                do {
                    try fm.removeItem(at: item.url)
                    count(&out, size)
                } catch {
                    out.failed.append((path, error.localizedDescription))
                }
            case .orphanedWorktree:
                guard case .orphaned = DevWorktreeLink.classify(path) else {
                    out.skipped.append((path, "no longer an orphaned worktree")); continue
                }
                do {
                    try fm.removeItem(at: item.url)
                    count(&out, size)
                } catch {
                    out.failed.append((path, error.localizedDescription))
                }
            case .worktree:
                switch DevWorktreeLink.classify(path) {
                case .mainCheckout:
                    out.skipped.append((path, "main checkout, not a linked worktree"))
                case .none, .orphaned:
                    out.skipped.append((path, "not a git worktree"))
                case .linked(let common):
                    let list = Git.run(["--git-dir=\(common)", "worktree", "list", "--porcelain"])
                    let entries = list.status == 0 ? DevWorktreeEntry.parse(list.out) : []
                    guard let entry = entries.first(where: { $0.path == path }) else {
                        out.skipped.append((path, "not registered with its repository")); continue
                    }
                    if entry.isMain { out.skipped.append((path, "main checkout, not a linked worktree")); continue }
                    if entry.locked { out.skipped.append((path, "locked")); continue }
                    if entry.detached, Git.unpushedCount(at: path, includeBranches: true) != 0 {
                        out.skipped.append((path, "detached HEAD with commits not on any branch or remote")); continue
                    }
                    let result = Git.run(["--git-dir=\(common)", "worktree", "remove", path], timeout: 300)
                    touched.insert(common)
                    if result.status != 0 {
                        let reason = result.err.split(separator: "\n").first.map(String.init) ?? "git worktree remove failed"
                        out.failed.append((path, reason.replacingOccurrences(of: "fatal: ", with: "")))
                    } else if fm.fileExists(atPath: path) {
                        out.failed.append((path, "item survived removal"))
                    } else {
                        count(&out, size)
                    }
                }
            }
        }
        for common in touched { _ = Git.run(["--git-dir=\(common)", "worktree", "prune"]) }
        return out
    }

    private static func count(_ out: inout DevProjectRemovalOutcome, _ bytes: Int64) {
        out.removed += 1
        let (sum, overflow) = out.freedBytes.addingReportingOverflow(bytes)
        out.freedBytes = overflow ? .max : sum
    }

    // MARK: - Safety

    static func isValidScanRoot(_ url: URL) -> Bool {
        let home = NSHomeDirectory()
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var blocked: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/Volumes", home]
        for dir in ["Library", "Pictures", "Music", "Movies", "Public"] { blocked.insert("\(home)/\(dir)") }
        if blocked.contains(path) { return false }
        let deniedTrees = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private/etc", "/cores", "\(home)/Library", "\(home)/Pictures", "\(home)/Music", "\(home)/Movies", "\(home)/Public"]
        if deniedTrees.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        if isCloudPath(path) { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func unsafeReason(_ path: String, excludedPaths: [String]) -> String? {
        let home = NSHomeDirectory()
        guard path.hasPrefix("/"), !path.contains("\0") else { return "invalid path" }
        let std = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        if std == "/" || resolved == "/" || resolved == home { return "protected root" }
        if hasSymlinkComponent(std) { return "symlink" }
        let denied = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/cores", "\(home)/Library"]
        if denied.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) { return "protected system path" }
        if isCloudPath(std) { return "cloud/provider state" }
        if CleanupExclusions.excludes(std, paths: excludedPaths) { return "excluded" }
        if FileProtection.isProtectedFromDeletion(path: std) { return "protected by macOS" }
        if !FileManager.default.fileExists(atPath: std) { return "missing" }
        return nil
    }

    private static func hasSymlinkComponent(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path.count > 1 {
            // /var, /tmp and /etc are system-level symlinks, not user-planted ones.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
               !["/var", "/tmp", "/etc"].contains(url.path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }

    private static func isCloudPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path.hasPrefix("\(home)/Library/CloudStorage") || path.hasPrefix("\(home)/Library/Mobile Documents")
    }

    // MARK: - Small helpers

    private static func projectName(for url: URL, under root: URL, fallback: URL) -> String {
        let base = root.path + "/"
        guard url.path.hasPrefix(base) else { return fallback.lastPathComponent }
        let relative = String(url.path.dropFirst(base.count))
        let components = relative.split(separator: "/")
        return components.count > 1 ? String(components[0]) : root.lastPathComponent
    }

    private static func modifiedDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileID(_ path: String) -> DevProjectFileID? {
        var sb = stat()
        guard lstat(path, &sb) == 0 else { return nil }
        return DevProjectFileID(device: UInt64(bitPattern: Int64(sb.st_dev)), inode: UInt64(sb.st_ino))
    }
}

// MARK: - Git

enum Git {
    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    static let executable: String? = [
        "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Read-only calls pass `--no-optional-locks` so scanning never touches an index.
    static func run(_ args: [String], timeout: TimeInterval = 120) -> Result {
        guard let executable else { return Result(status: 127, out: "", err: "git not found") }
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--no-optional-locks"] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        do { try process.run() } catch { return Result(status: 126, out: "", err: "failed to launch git") }
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            group.wait()
            return Result(status: 124, out: "", err: "git timed out")
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Commits reachable from HEAD that exist on no remote (and optionally no local branch).
    /// Returns -1 when git cannot answer.
    static func unpushedCount(at path: String, includeBranches: Bool) -> Int {
        var args = ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"]
        if includeBranches { args.append("--branches") }
        let result = run(args)
        guard result.status == 0, let n = Int(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return -1 }
        return n
    }
}

struct DevWorktreeEntry: Equatable {
    var path: String
    var branch: String?
    var detached = false
    var locked = false
    var prunable = false
    var isMain = false

    static func parse(_ porcelain: String) -> [DevWorktreeEntry] {
        var entries: [DevWorktreeEntry] = []
        var current: DevWorktreeEntry?
        func flush() {
            if var entry = current {
                entry.isMain = entries.isEmpty
                entries.append(entry)
            }
            current = nil
        }
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()
                let raw = String(line.dropFirst("worktree ".count))
                current = DevWorktreeEntry(path: URL(fileURLWithPath: raw).resolvingSymlinksInPath().path)
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                current?.detached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            }
        }
        flush()
        return entries
    }
}

enum DevWorktreeLink: Equatable {
    case mainCheckout
    case linked(commonDir: String)
    case orphaned
    case none

    static func classify(_ dir: String) -> DevWorktreeLink {
        let gitPath = dir + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return .none }
        if isDir.boolValue { return .mainCheckout }
        guard let text = try? String(contentsOfFile: gitPath, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return .none }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitdir = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL
        let parent = gitdir.deletingLastPathComponent()
        guard parent.lastPathComponent == "worktrees" else { return .none }
        guard FileManager.default.fileExists(atPath: gitdir.path) else { return .orphaned }
        return .linked(commonDir: parent.deletingLastPathComponent().resolvingSymlinksInPath().path)
    }
}
