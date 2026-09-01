import XCTest
@testable import PureMac

final class GitWorktreeScannerTests: XCTestCase {
    private var temporaryHome: URL!
    private let gitPath = "/usr/bin/git"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Keep destructive Git fixtures under the checkout's build directory.
        // This is portable and keeps every fixture on the checkout's volume.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        temporaryHome = sourceRoot
            .appendingPathComponent("build/TestWorktrees", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryHome {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        try super.tearDownWithError()
    }

    func testPorcelainParserHandlesNULFieldsReasonsAndDetachedRecords() {
        let payload = [
            "worktree /Volumes/Test/main", "HEAD aaaa", "branch refs/heads/main", "",
            "worktree /Volumes/Test/locked tree", "HEAD bbbb", "detached", "locked agent is running", "",
            "worktree /Volumes/Test/gone", "HEAD cccc", "detached", "prunable gitdir file points to non-existent location", "",
        ].joined(separator: "\0") + "\0"

        let records = GitWorktreeScanner.parseWorktreeList(Data(payload.utf8))

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].branch, "refs/heads/main")
        XCTAssertEqual(records[1].path, "/Volumes/Test/locked tree")
        XCTAssertTrue(records[1].isDetached)
        XCTAssertTrue(records[1].isLocked)
        XCTAssertTrue(records[2].isPrunable)
    }

    func testScanFindsCodexClaudeOMPCursorPiAndManualWorktrees() throws {
        let repository = try makeRepository(named: "provider-repo")
        let worktrees = [
            temporaryHome.appendingPathComponent(".codex/worktrees/session/provider-repo"),
            repository.appendingPathComponent(".claude/worktrees/claude-task"),
            temporaryHome.appendingPathComponent(".omp/wt/provider-repo/omp-task"),
            temporaryHome.appendingPathComponent(".cursor/worktrees/session/provider-repo"),
            temporaryHome.appendingPathComponent(".pi/worktrees/pi-task"),
            temporaryHome.appendingPathComponent("Developer/provider-repo-manual"),
        ]

        for worktree in worktrees {
            try FileManager.default.createDirectory(
                at: worktree.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try runGit(["-C", repository.path, "worktree", "add", "--detach", worktree.path, "HEAD"])
            try ageContents(of: worktree, byDays: 60)
        }

        let items = makeScanner().scan()
        let names = Set(items.map(\.name))

        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(names.contains("Codex Worktree — provider-repo"))
        XCTAssertTrue(names.contains("Claude Code Worktree — provider-repo"))
        XCTAssertTrue(names.contains("Oh My Pi Worktree — provider-repo"))
        XCTAssertTrue(names.contains("Cursor Worktree — provider-repo"))
        XCTAssertTrue(names.contains("Pi Worktree — provider-repo"))
        XCTAssertTrue(names.contains("Git Worktree — provider-repo"))
        XCTAssertTrue(items.allSatisfy { !$0.isSelected })
        XCTAssertEqual(Set(items.compactMap(\.gitWorktreePath)), Set(worktrees.map(\.path)))
    }

    func testScanFindsWorktreesOnConnectedWritableVolumes() throws {
        let isolatedHome = temporaryHome.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let connectedVolume = temporaryHome.appendingPathComponent("ConnectedVolume", isDirectory: true)
        let repository = try makeRepository(named: "volume-repo", under: connectedVolume)
        let worktree = connectedVolume.appendingPathComponent("Worktrees/old-task", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runGit(["-C", repository.path, "worktree", "add", "--detach", worktree.path, "HEAD"])
        try ageContents(of: worktree, byDays: 60)
        let items = makeScanner(
            homeURL: isolatedHome,
            mountedVolumeURLs: [connectedVolume]
        ).scan()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.gitWorktreePath, worktree.path)
        XCTAssertEqual(items.first?.name, "Git Worktree — volume-repo")
    }

    func testScanExcludesRecentDirtyLockedAndUnreferencedDetachedWorktrees() throws {
        let repository = try makeRepository(named: "safety-repo")
        let recent = temporaryHome.appendingPathComponent("Developer/recent")
        let dirty = temporaryHome.appendingPathComponent("Developer/dirty")
        let locked = temporaryHome.appendingPathComponent("Developer/locked")
        let uniqueCommit = temporaryHome.appendingPathComponent("Developer/unique-commit")

        for worktree in [recent, dirty, locked, uniqueCommit] {
            try FileManager.default.createDirectory(
                at: worktree.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try runGit(["-C", repository.path, "worktree", "add", "--detach", worktree.path, "HEAD"])
        }

        try Data("untracked".utf8).write(to: dirty.appendingPathComponent("notes.txt"))
        try runGit(["-C", repository.path, "worktree", "lock", locked.path])
        try Data("committed work".utf8).write(to: uniqueCommit.appendingPathComponent("unique.txt"))
        try runGit(["-C", uniqueCommit.path, "add", "unique.txt"])
        try runGit(["-C", uniqueCommit.path, "commit", "-m", "unique detached commit"])

        for worktree in [dirty, locked, uniqueCommit] {
            try ageContents(of: worktree, byDays: 60)
        }
        try ageContents(of: recent, byDays: 2)

        XCTAssertTrue(makeScanner().scan().isEmpty)
    }

    func testRemoveWorktreePreservesItsBranch() throws {
        let repository = try makeRepository(named: "branch-repo")
        let worktree = temporaryHome.appendingPathComponent("Developer/branch-worktree")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runGit(["-C", repository.path, "worktree", "add", "-b", "keep-this-branch", worktree.path, "HEAD"])
        try ageContents(of: worktree, byDays: 60)

        let scanner = makeScanner()
        XCTAssertEqual(scanner.scan().count, 1)

        let result = scanner.removeWorktree(at: worktree.path)

        XCTAssertTrue(result.removed, result.error ?? "Expected Git removal to succeed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        let branchResult = GitWorktreeScanner.runCommand(
            gitPath,
            ["-C", repository.path, "show-ref", "--verify", "--quiet", "refs/heads/keep-this-branch"]
        )
        XCTAssertEqual(branchResult.status, 0, "Removing a worktree must preserve its branch")
    }

    func testRemoveWorktreeRechecksDirtyStateAfterScan() throws {
        let repository = try makeRepository(named: "race-repo")
        let worktree = temporaryHome.appendingPathComponent("Developer/race-worktree")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runGit(["-C", repository.path, "worktree", "add", "--detach", worktree.path, "HEAD"])
        try ageContents(of: worktree, byDays: 60)

        let scanner = makeScanner()
        XCTAssertEqual(scanner.scan().count, 1)
        try Data("new work".utf8).write(to: worktree.appendingPathComponent("do-not-delete.txt"))

        let result = scanner.removeWorktree(at: worktree.path)

        XCTAssertFalse(result.removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(result.error?.contains("changed") == true)
    }

    func testCleaningEngineRoutesWorktreeItemsThroughGit() async throws {
        let repository = try makeRepository(named: "engine-repo")
        let worktree = temporaryHome.appendingPathComponent("Developer/engine-worktree")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runGit(["-C", repository.path, "worktree", "add", "-b", "engine-branch", worktree.path, "HEAD"])
        try ageContents(of: worktree, byDays: 60)
        let item = try XCTUnwrap(makeScanner().scan().first)

        let result = await CleaningEngine().cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.freedSpace, item.size)
        XCTAssertTrue(result.cleanedPaths.contains(item.path))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testCleanableItemExposesRealWorktreePathForFinder() {
        let item = CleanableItem(
            name: "Codex Worktree — app",
            path: CleanableItem.gitWorktreePathPrefix + "/Users/test/.codex/worktrees/task/app",
            size: 4096,
            category: .aiApps,
            isSelected: false,
            lastModified: nil
        )

        XCTAssertEqual(item.gitWorktreePath, "/Users/test/.codex/worktrees/task/app")
        XCTAssertEqual(item.fileSystemPath, "/Users/test/.codex/worktrees/task/app")
        XCTAssertFalse(item.isActionItem)
    }

    // MARK: - Fixtures

    private func makeScanner(
        homeURL: URL? = nil,
        mountedVolumeURLs: [URL] = []
    ) -> GitWorktreeScanner {
        GitWorktreeScanner(
            homeURL: homeURL ?? temporaryHome,
            mountedVolumeURLs: mountedVolumeURLs,
            now: Date(),
            inactivityInterval: 30 * 24 * 60 * 60,
            gitExecutablePath: gitPath
        )
    }

    private func makeRepository(named name: String, under root: URL? = nil) throws -> URL {
        let repositoryRoot = root ?? temporaryHome.appendingPathComponent("Developer", isDirectory: true)
        let repository = repositoryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main", repository.path])
        try runGit(["-C", repository.path, "config", "user.name", "PureMac Tests"])
        try runGit(["-C", repository.path, "config", "user.email", "puremac-tests@example.invalid"])
        try Data(repeating: 0x41, count: 8192).write(to: repository.appendingPathComponent("seed.bin"))
        try runGit(["-C", repository.path, "add", "seed.bin"])
        try runGit(["-C", repository.path, "commit", "-m", "initial"])
        return repository
    }

    private func ageContents(of directory: URL, byDays days: Int) throws {
        let oldDate = Date().addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == ".git" && url.deletingLastPathComponent() == directory {
                    continue
                }
                try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.path)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> GitWorktreeScanner.CommandResult {
        let result = GitWorktreeScanner.runCommand(gitPath, arguments)
        guard result.status == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeScannerTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(stderr)"]
            )
        }
        return result
    }
}
