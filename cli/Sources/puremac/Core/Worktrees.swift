import Foundation

/// Thin wrapper over the system `git` binary. Read-only calls pass
/// `--no-optional-locks` so scanning never touches a repository's index.
enum Git {
    static let executable: String? = [
        "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String], timeout: TimeInterval = 60) -> Shell.Result {
        guard let executable else {
            return Shell.Result(status: 127, out: "", err: "git not found")
        }
        return Shell.run(executable, ["--no-optional-locks"] + args, timeout: timeout)
    }

    static func lines(_ result: Shell.Result) -> [String] {
        result.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// One entry of `git worktree list --porcelain`.
struct WorktreeEntry: Equatable {
    var path: String
    var branch: String?
    var detached = false
    var locked = false
    var prunable = false
    var isMain = false

    static func parse(_ porcelain: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
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
                current = WorktreeEntry(path: URL(fileURLWithPath: raw).resolvingSymlinksInPath().path)
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

/// How a directory's `.git` entry relates to a repository.
enum WorktreeLink: Equatable {
    /// `.git` is a directory: a main checkout.
    case mainCheckout
    /// `.git` file points at `<common>/worktrees/<name>`, which exists.
    case linked(commonDir: String)
    /// `.git` file points at a git dir that no longer exists.
    case orphaned
    /// Not a linked worktree (no `.git`, a submodule, unreadable, …).
    case none

    static func classify(_ dir: String) -> WorktreeLink {
        let gitPath = dir + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return .none }
        if isDir.boolValue { return .mainCheckout }
        guard let text = try? String(contentsOfFile: gitPath, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return .none }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitdir = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: dir, isDirectory: true))
            .standardizedFileURL
        let parent = gitdir.deletingLastPathComponent()
        guard parent.lastPathComponent == "worktrees" else { return .none }
        guard FileManager.default.fileExists(atPath: gitdir.path) else { return .orphaned }
        return .linked(commonDir: parent.deletingLastPathComponent().resolvingSymlinksInPath().path)
    }
}

enum WorktreeScanner {
    /// Per-repo folders where agents and tools park worktrees.
    static let conventionalDirs = [".claude/worktrees", ".orc", ".supacode"]

    /// Extra roots scanned in addition to the user's folders.
    static var globalExtraRoots: [String] {
        ["\(Safety.home)/.supacode"].filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static let maxDepth = 6

    static func scan(
        roots: [String],
        extraRoots: [String] = [],
        olderThanDays: Int,
        ignore: IgnoreStore,
        artifacts: [ScanItem] = []
    ) -> CategoryScan {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        let userRoots = Purger.scanRoots(roots)
        let extras = Purger.scanRoots(extraRoots)
        let allRoots = userRoots + extras

        var commonDirs: [String: String] = [:]   // commonDir -> repo display name
        var orphans: [String] = []
        func normalized(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        var allowedPrefixes = allRoots.map(\.path)

        func register(commonDir: String, name: String? = nil) {
            if commonDirs[commonDir] == nil {
                let repoDir = (commonDir as NSString).lastPathComponent == ".git"
                    ? (commonDir as NSString).deletingLastPathComponent : commonDir
                commonDirs[commonDir] = name ?? (repoDir as NSString).lastPathComponent
            }
        }

        func inspect(_ dir: String) -> Bool {
            switch WorktreeLink.classify(dir) {
            case .mainCheckout:
                let common = URL(fileURLWithPath: dir + "/.git").resolvingSymlinksInPath().path
                register(commonDir: common)
                for conv in conventionalDirs { allowedPrefixes.append(dir + "/" + conv) }
                findConventional(in: dir, ignore: ignore, register: register, orphan: { orphans.append(normalized($0)) })
                return true
            case .linked(let common):
                register(commonDir: common)
                return true
            case .orphaned:
                orphans.append(normalized(dir))
                return true
            case .none:
                return false
            }
        }

        for root in allRoots {
            _ = inspect(root.path)
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in en {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { en.skipDescendants(); continue }
                guard vals?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                if name == ".git" || Purger.isArtifact(name) || en.level > maxDepth {
                    en.skipDescendants()
                    continue
                }
                if Safety.isCloudOrDataless(url.path) || Safety.isPathIgnored(url.path, ignore: ignore) {
                    en.skipDescendants()
                    continue
                }
                if inspect(url.path) { en.skipDescendants() }
            }
        }

        // Collect registered worktrees from every repository found.
        var found: [(entry: WorktreeEntry, common: String)] = []
        var seen = Set<String>()
        for (common, _) in commonDirs.sorted(by: { $0.key < $1.key }) {
            let result = Git.run(["--git-dir=\(common)", "worktree", "list", "--porcelain"])
            guard result.status == 0 else { continue }
            for entry in WorktreeEntry.parse(result.out) where !entry.isMain && !entry.prunable {
                guard allowedPrefixes.contains(where: { entry.path.hasPrefix($0 + "/") }),
                      seen.insert(entry.path).inserted else { continue }
                found.append((entry, common))
            }
        }

        var byRepo: [String: [ScanItem]] = [:]
        for (entry, common) in found {
            if Safety.isPathIgnored(entry.path, ignore: ignore) { continue }
            let item = makeItem(entry, cutoff: cutoff, ignore: ignore, artifacts: artifacts)
            byRepo[commonDirs[common] ?? "repository", default: []].append(item)
        }
        for orphan in Set(orphans).sorted() where !seen.contains(orphan) {
            if Safety.isPathIgnored(orphan, ignore: ignore) { continue }
            let m = DirSizer.measure(of: orphan)
            let size = max(0, m.bytes - nestedBytes(under: orphan, artifacts: artifacts))
            byRepo["orphaned worktrees", default: []].append(
                ScanItem(path: orphan, sizeBytes: size, modified: DirSizer.modified(of: orphan),
                         selected: false, note: "orphaned: repository missing")
            )
        }

        let groups = byRepo.map { repo, items in
            ToolGroup(tool: repo, items: items.sorted { $0.sizeBytes > $1.sizeBytes })
        }.sorted { $0.allBytes > $1.allBytes }
        return CategoryScan(id: "worktrees", title: "Git Worktrees", groups: groups)
    }

    private static func findConventional(
        in repo: String,
        ignore: IgnoreStore,
        register: (String, String?) -> Void,
        orphan: (String) -> Void
    ) {
        let fm = FileManager.default
        for conv in conventionalDirs {
            let base = URL(fileURLWithPath: repo + "/" + conv, isDirectory: true)
            guard fm.fileExists(atPath: base.path),
                  let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { en.skipDescendants(); continue }
                guard vals?.isDirectory == true else { continue }
                if en.level > 2 || Purger.isArtifact(url.lastPathComponent) { en.skipDescendants(); continue }
                switch WorktreeLink.classify(url.path) {
                case .linked(let common): register(common, nil); en.skipDescendants()
                case .orphaned: orphan(url.path); en.skipDescendants()
                case .mainCheckout: en.skipDescendants()
                case .none: continue
                }
            }
        }
    }

    private static func makeItem(
        _ entry: WorktreeEntry,
        cutoff: Date,
        ignore: IgnoreStore,
        artifacts: [ScanItem]
    ) -> ScanItem {
        let measurement = DirSizer.measure(of: entry.path)
        let size = max(0, measurement.bytes - nestedBytes(under: entry.path, artifacts: artifacts))

        var commitDate: Date?
        let log = Git.run(["-C", entry.path, "log", "-1", "--format=%ct"], timeout: 30)
        if log.status == 0, let secs = TimeInterval(log.out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            commitDate = Date(timeIntervalSince1970: secs)
        }
        let modified = commitDate ?? DirSizer.modified(of: entry.path)

        let note: String?
        if entry.locked {
            note = "locked"
        } else {
            let status = Git.run(["-C", entry.path, "status", "--porcelain"], timeout: 60)
            if status.status != 0 {
                note = "git status failed"
            } else if !status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note = "uncommitted changes"
            } else if unpushedCount(at: entry.path, includeBranches: false) != 0 {
                note = "unpushed commits"
            } else if let modified, modified > cutoff {
                note = "recent"
            } else if measurement.status != .complete {
                note = "partially measured"
            } else {
                note = nil
            }
        }
        return ScanItem(path: entry.path, sizeBytes: size, modified: modified, selected: note == nil, note: note)
    }

    /// Commits reachable from HEAD that exist on no remote (and, optionally, no local branch).
    /// Returns -1 when git cannot answer.
    static func unpushedCount(at path: String, includeBranches: Bool) -> Int {
        var args = ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"]
        if includeBranches { args.append("--branches") }
        let result = Git.run(args, timeout: 60)
        guard result.status == 0, let n = Int(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return -1 }
        return n
    }

    private static func nestedBytes(under path: String, artifacts: [ScanItem]) -> Int64 {
        artifacts.filter { $0.path.hasPrefix(path + "/") }.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
}

enum WorktreeRemover {
    static func remove(_ items: [ScanItem], ignore: IgnoreStore, dryRun: Bool) -> CleanOutcome {
        var out = CleanOutcome()
        var touched = Set<String>()
        let fm = FileManager.default

        for item in items {
            let verdict = Safety.canRemove(item.path, ignore: ignore)
            guard verdict.ok else { out.skipped.append((item.path, verdict.reason ?? "protected")); continue }
            guard let expected = item.identity, Safety.fileIdentity(at: item.path) == expected else {
                out.skipped.append((item.path, "changed since scan")); continue
            }

            switch WorktreeLink.classify(item.path) {
            case .none:
                out.skipped.append((item.path, "not a git worktree"))
            case .mainCheckout:
                out.skipped.append((item.path, "main checkout, not a linked worktree"))
            case .orphaned:
                let m = DirSizer.measure(of: item.path)
                guard m.status == .complete else { out.skipped.append((item.path, "could not measure safely")); continue }
                if dryRun { count(&out, m.bytes); continue }
                do {
                    try fm.removeItem(atPath: item.path)
                    count(&out, m.bytes)
                } catch {
                    out.failed.append((item.path, error.localizedDescription))
                }
            case .linked(let common):
                let list = Git.run(["--git-dir=\(common)", "worktree", "list", "--porcelain"])
                let entries = list.status == 0 ? WorktreeEntry.parse(list.out) : []
                guard let entry = entries.first(where: { $0.path == item.path }) else {
                    out.skipped.append((item.path, "not registered with its repository")); continue
                }
                if entry.isMain { out.skipped.append((item.path, "main checkout, not a linked worktree")); continue }
                if entry.locked { out.skipped.append((item.path, "locked")); continue }
                if entry.detached, WorktreeScanner.unpushedCount(at: item.path, includeBranches: true) != 0 {
                    out.skipped.append((item.path, "detached HEAD with commits not on any branch or remote")); continue
                }
                let m = DirSizer.measure(of: item.path)
                if dryRun { count(&out, m.bytes); continue }
                // No --force: git itself refuses dirty or locked worktrees.
                let result = Git.run(["--git-dir=\(common)", "worktree", "remove", item.path], timeout: 300)
                touched.insert(common)
                if result.status != 0 {
                    let reason = result.err.split(separator: "\n").first.map(String.init) ?? "git worktree remove failed"
                    out.failed.append((item.path, reason.replacingOccurrences(of: "fatal: ", with: "")))
                } else if fm.fileExists(atPath: item.path) {
                    out.failed.append((item.path, "item survived removal"))
                } else {
                    count(&out, m.bytes)
                }
            }
        }
        for common in touched { _ = Git.run(["--git-dir=\(common)", "worktree", "prune"]) }
        return out
    }

    private static func count(_ out: inout CleanOutcome, _ bytes: Int64) {
        out.removed += 1
        let (sum, overflow) = out.freedBytes.addingReportingOverflow(bytes)
        out.freedBytes = overflow ? .max : sum
    }
}
