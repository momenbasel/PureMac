import Foundation

/// Finds old, clean linked worktrees across the user's home and writable local
/// mounted volumes, then removes them through Git rather than unlinking their
/// directories directly. Git remains the source of truth for registration,
/// locks, dirty state, branches, and detached commits.
struct GitWorktreeScanner {
    static let defaultInactivityInterval: TimeInterval = 30 * 24 * 60 * 60

    struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    struct WorktreeRecord: Equatable {
        let path: String
        let head: String?
        let branch: String?
        let isDetached: Bool
        let isBare: Bool
        let isLocked: Bool
        let isPrunable: Bool
    }

    struct RemovalResult {
        let removed: Bool
        let error: String?
    }

    typealias CommandRunner = (_ executablePath: String, _ arguments: [String]) -> CommandResult

    private struct WorktreeMetrics {
        let size: Int64
        let lastModified: Date
    }

    private struct WorktreeRecordBuilder {
        var path: String?
        var head: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var isPrunable = false
    }

    private let fileManager: FileManager
    private let homeURL: URL
    /// `nil` discovers mounted volumes at scan time. Tests can pass an explicit
    /// list (including an empty one) to keep discovery deterministic.
    private let mountedVolumeURLs: [URL]?
    private let now: Date
    private let inactivityInterval: TimeInterval
    private let gitExecutablePath: String?
    private let commandRunner: CommandRunner

    init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        mountedVolumeURLs: [URL]? = nil,
        now: Date = Date(),
        inactivityInterval: TimeInterval = GitWorktreeScanner.defaultInactivityInterval,
        gitExecutablePath: String? = GitWorktreeScanner.defaultGitExecutablePath(),
        commandRunner: @escaping CommandRunner = GitWorktreeScanner.runCommand
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL.standardizedFileURL
        self.mountedVolumeURLs = mountedVolumeURLs?.map(\.standardizedFileURL)
        self.now = now
        self.inactivityInterval = inactivityInterval
        self.gitExecutablePath = gitExecutablePath
        self.commandRunner = commandRunner
    }

    /// Returns opt-in cleanup rows for linked worktrees that are:
    /// - at least 30 days inactive by default,
    /// - registered and unlocked,
    /// - clean according to Git, and
    /// - backed by a branch/ref so removing the checkout cannot orphan commits.
    func scan(
        report: ((String) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> [CleanableItem] {
        guard let gitExecutablePath else { return [] }

        var lastReportedAt = Date.distantPast
        let throttledReport: (String) -> Void = { path in
            guard let report else { return }
            let reportDate = Date()
            guard reportDate.timeIntervalSince(lastReportedAt) > 0.1 else { return }
            lastReportedAt = reportDate
            report(path)
        }

        let repositoryRoots = discoverRepositoryRoots(report: throttledReport, isCancelled: isCancelled)
        var seenCommonDirectories: Set<String> = []
        var seenWorktreePaths: Set<String> = []
        var items: [CleanableItem] = []
        let staleBefore = now.addingTimeInterval(-inactivityInterval)

        for repositoryRoot in repositoryRoots.sorted() {
            if isCancelled() { break }
            guard let commonDirectory = commonGitDirectory(
                for: repositoryRoot,
                gitExecutablePath: gitExecutablePath
            ), seenCommonDirectories.insert(commonDirectory).inserted else {
                continue
            }

            let listResult = runGit(
                ["--git-dir", commonDirectory, "worktree", "list", "--porcelain", "-z"],
                gitExecutablePath: gitExecutablePath
            )
            guard listResult.status == 0 else { continue }

            let repositoryName = Self.repositoryName(forCommonDirectory: commonDirectory)
            for record in Self.parseWorktreeList(listResult.stdout) {
                if isCancelled() { break }
                let normalizedPath = Self.normalizePath(record.path)
                guard seenWorktreePaths.insert(normalizedPath).inserted,
                      isLinkedWorktree(at: normalizedPath),
                      isSafeToRemove(
                        record,
                        commonDirectory: commonDirectory,
                        gitExecutablePath: gitExecutablePath
                      ) else {
                    continue
                }

                throttledReport(normalizedPath)
                let metrics = worktreeMetrics(
                    at: normalizedPath,
                    report: throttledReport,
                    isCancelled: isCancelled
                )
                guard metrics.size > 1024, metrics.lastModified <= staleBefore else { continue }

                let provider = Self.providerName(for: normalizedPath)
                let name = String(
                    format: String(localized: "%@ Worktree — %@"),
                    provider,
                    repositoryName
                )
                items.append(CleanableItem(
                    name: name,
                    path: CleanableItem.gitWorktreePathPrefix + normalizedPath,
                    size: metrics.size,
                    category: .aiApps,
                    isSelected: false,
                    lastModified: metrics.lastModified
                ))
            }
        }

        return items.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Re-checks every scan invariant immediately before asking Git to remove
    /// the linked worktree. `--force` is deliberately never used.
    func removeWorktree(at path: String) -> RemovalResult {
        guard let gitExecutablePath else {
            return RemovalResult(removed: false, error: "Git is not available")
        }

        let normalizedPath = Self.normalizePath(path)
        guard isLinkedWorktree(at: normalizedPath),
              let commonDirectory = commonGitDirectory(
                for: normalizedPath,
                gitExecutablePath: gitExecutablePath
              ) else {
            return RemovalResult(removed: false, error: "Not a registered linked worktree")
        }

        let listResult = runGit(
            ["--git-dir", commonDirectory, "worktree", "list", "--porcelain", "-z"],
            gitExecutablePath: gitExecutablePath
        )
        guard listResult.status == 0,
              let record = Self.parseWorktreeList(listResult.stdout).first(where: {
                Self.normalizePath($0.path) == normalizedPath
              }),
              isSafeToRemove(
                record,
                commonDirectory: commonDirectory,
                gitExecutablePath: gitExecutablePath
              ) else {
            return RemovalResult(
                removed: false,
                error: "Worktree is active, changed, locked, or contains unreferenced commits"
            )
        }

        let removeResult = runGit(
            ["--git-dir", commonDirectory, "worktree", "remove", normalizedPath],
            gitExecutablePath: gitExecutablePath
        )
        guard removeResult.status == 0 else {
            let detail = Self.string(from: removeResult.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RemovalResult(
                removed: false,
                error: detail.isEmpty ? "Git refused to remove the worktree" : detail
            )
        }

        guard !fileManager.fileExists(atPath: normalizedPath) else {
            return RemovalResult(removed: false, error: "Worktree still exists after Git cleanup")
        }
        return RemovalResult(removed: true, error: nil)
    }

    // MARK: - Discovery

    private func discoverRepositoryRoots(
        report: ((String) -> Void)?,
        isCancelled: () -> Bool
    ) -> Set<String> {
        var roots: Set<String> = []
        var discoveryRoots = [homeURL]
        discoveryRoots.append(contentsOf: mountedVolumeURLs ?? discoverMountedVolumeURLs())

        let environment = ProcessInfo.processInfo.environment
        if let codexHome = expandedAbsolutePath(environment["CODEX_HOME"]) {
            discoveryRoots.append(URL(fileURLWithPath: codexHome).appendingPathComponent("worktrees"))
        }
        if let ompWorktrees = expandedAbsolutePath(environment["OMP_WORKTREE_DIR"]) {
            discoveryRoots.append(URL(fileURLWithPath: ompWorktrees))
        }

        for discoveryRoot in Set(discoveryRoots.map(\.standardizedFileURL)) {
            if isCancelled() { break }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: discoveryRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            if hasGitMarker(at: discoveryRoot) {
                roots.insert(discoveryRoot.path)
                continue
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let enumerator = fileManager.enumerator(
                at: discoveryRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                if isCancelled() { break }
                report?(url.path)
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }

                if shouldPruneDirectory(url, discoveryRoot: discoveryRoot) {
                    enumerator.skipDescendants()
                    continue
                }
                if hasGitMarker(at: url) {
                    roots.insert(url.standardizedFileURL.path)
                    enumerator.skipDescendants()
                }
            }
        }

        return roots
    }
    private func discoverMountedVolumeURLs() -> [URL] {
        let keys: Set<URLResourceKey> = [
            .volumeIsBrowsableKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
        ]
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { volumeURL in
            let volume = volumeURL.standardizedFileURL
            let path = volume.path

            // The startup volume is already covered by the user's home. APFS
            // support volumes are implementation details, not user disks.
            guard path != "/", !path.hasPrefix("/System/Volumes/") else { return nil }
            guard let values = try? volume.resourceValues(forKeys: keys) else { return nil }
            guard values.volumeIsBrowsable != false,
                  values.volumeIsLocal != false,
                  values.volumeIsReadOnly != true else {
                return nil
            }
            return volume
        }
    }

    private func hasGitMarker(at directory: URL) -> Bool {
        let markerPath = directory.appendingPathComponent(".git", isDirectory: false).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: markerPath),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory || type == .typeRegular
    }

    private func isLinkedWorktree(at path: String) -> Bool {
        let markerPath = (path as NSString).appendingPathComponent(".git")
        guard let attributes = try? fileManager.attributesOfItem(atPath: markerPath),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func shouldPruneDirectory(_ url: URL, discoveryRoot: URL) -> Bool {
        let name = url.lastPathComponent
        let generatedDirectoryNames: Set<String> = [
            "node_modules", "DerivedData", "Pods", ".build", "build", "dist",
            "target", ".swiftpm", ".venv", "venv", "vendor", ".cache", ".npm",
        ]
        if generatedDirectoryNames.contains(name) { return true }

        if url.deletingLastPathComponent().standardizedFileURL == homeURL {
            let nonDevelopmentHomeDirectories: Set<String> = [
                "Library", "Applications", "Movies", "Music", "Pictures", "Public", ".Trash",
            ]
            if nonDevelopmentHomeDirectories.contains(name) { return true }
        }

        if url.deletingLastPathComponent().standardizedFileURL == discoveryRoot.standardizedFileURL {
            let volumeMetadataDirectories: Set<String> = [
                ".DocumentRevisions-V100", ".Spotlight-V100", ".TemporaryItems",
                ".Trashes", ".fseventsd", "Backups.backupdb", "System Volume Information",
                "lost+found",
            ]
            if volumeMetadataDirectories.contains(name) { return true }
        }

        return false
    }

    private func expandedAbsolutePath(_ rawPath: String?) -> String? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return Self.normalizePath(expanded)
    }

    // MARK: - Safety checks

    private func commonGitDirectory(for repositoryPath: String, gitExecutablePath: String) -> String? {
        let result = runGit(
            ["-C", repositoryPath, "rev-parse", "--git-common-dir"],
            gitExecutablePath: gitExecutablePath
        )
        guard result.status == 0 else { return nil }

        let rawPath = Self.string(from: result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") { return Self.normalizePath(rawPath) }
        return URL(fileURLWithPath: rawPath, relativeTo: URL(fileURLWithPath: repositoryPath, isDirectory: true))
            .standardizedFileURL
            .path
    }

    private func isSafeToRemove(
        _ record: WorktreeRecord,
        commonDirectory: String,
        gitExecutablePath: String
    ) -> Bool {
        guard !record.isBare, !record.isLocked, !record.isPrunable,
              fileManager.fileExists(atPath: record.path),
              isGitClean(at: record.path, gitExecutablePath: gitExecutablePath),
              headIsPreserved(
                record,
                commonDirectory: commonDirectory,
                gitExecutablePath: gitExecutablePath
              ) else {
            return false
        }
        return true
    }

    private func isGitClean(at path: String, gitExecutablePath: String) -> Bool {
        let result = runGit(
            ["-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"],
            gitExecutablePath: gitExecutablePath
        )
        return result.status == 0 && result.stdout.isEmpty
    }

    private func headIsPreserved(
        _ record: WorktreeRecord,
        commonDirectory: String,
        gitExecutablePath: String
    ) -> Bool {
        if let branch = record.branch {
            let result = runGit(
                ["--git-dir", commonDirectory, "show-ref", "--verify", "--quiet", branch],
                gitExecutablePath: gitExecutablePath
            )
            return result.status == 0
        }

        guard record.isDetached, let head = record.head,
              !head.isEmpty, !head.allSatisfy({ $0 == "0" }) else {
            return false
        }
        let result = runGit(
            [
                "--git-dir", commonDirectory,
                "for-each-ref", "--format=%(refname)", "--contains=\(head)",
                "refs/heads", "refs/remotes", "refs/tags",
            ],
            gitExecutablePath: gitExecutablePath
        )
        return result.status == 0 && !result.stdout.isEmpty
    }

    // MARK: - Size and activity

    private func worktreeMetrics(
        at path: String,
        report: ((String) -> Void)?,
        isCancelled: () -> Bool
    ) -> WorktreeMetrics {
        let rootDate = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        var latestModification = rootDate
        var totalSize: Int64 = 0
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return WorktreeMetrics(size: 0, lastModified: latestModification)
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if isCancelled() { break }
            report?(fileURL.path)
            if fileURL.lastPathComponent == ".git",
               Self.normalizePath(fileURL.deletingLastPathComponent().path) == Self.normalizePath(path) {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            totalSize += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if let date = values.contentModificationDate, date > latestModification {
                latestModification = date
            }
        }

        return WorktreeMetrics(size: totalSize, lastModified: latestModification)
    }

    // MARK: - Porcelain parsing and process I/O

    static func parseWorktreeList(_ data: Data) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current = WorktreeRecordBuilder()

        func appendCurrent() {
            guard let path = current.path else { return }
            records.append(WorktreeRecord(
                path: path,
                head: current.head,
                branch: current.branch,
                isDetached: current.isDetached,
                isBare: current.isBare,
                isLocked: current.isLocked,
                isPrunable: current.isPrunable
            ))
            current = WorktreeRecordBuilder()
        }

        for fieldData in data.split(separator: 0, omittingEmptySubsequences: false) {
            guard !fieldData.isEmpty else {
                appendCurrent()
                continue
            }
            let field = String(decoding: fieldData, as: UTF8.self)
            if field.hasPrefix("worktree ") {
                if current.path != nil { appendCurrent() }
                current.path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                current.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                current.branch = String(field.dropFirst("branch ".count))
            } else if field == "detached" {
                current.isDetached = true
            } else if field == "bare" {
                current.isBare = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                current.isLocked = true
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                current.isPrunable = true
            }
        }
        appendCurrent()
        return records
    }

    private func runGit(_ arguments: [String], gitExecutablePath: String) -> CommandResult {
        commandRunner(gitExecutablePath, arguments)
    }

    static func runCommand(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func defaultGitExecutablePath(fileManager: FileManager = .default) -> String? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        guard fileManager.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        let developerDirectory = runCommand("/usr/bin/xcode-select", ["-p"])
        return developerDirectory.status == 0 ? "/usr/bin/git" : nil
    }

    private static func providerName(for path: String) -> String {
        let normalized = normalizePath(path)
        if normalized.contains("/.codex/worktrees/") { return "Codex" }
        if normalized.contains("/.claude/worktrees/") || normalized.contains("/.claude-worktrees/") {
            return "Claude Code"
        }
        if normalized.contains("/.cursor/worktrees/") { return "Cursor" }
        if normalized.contains("/.herdr/worktrees/")
            || normalized.contains("/herdr-worktrees/") {
            return "Herdr"
        }
        if normalized.contains("/.omp/wt/") { return "Oh My Pi" }
        if normalized.contains("/.pi/") || normalized.contains("/.git/worktrees/")
            || normalized.contains("/.worktrees/") || normalized.contains("/.worktree/") {
            return "Pi"
        }
        return "Git"
    }

    private static func repositoryName(forCommonDirectory path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == ".git" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        let name = url.lastPathComponent
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    private static func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func string(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
