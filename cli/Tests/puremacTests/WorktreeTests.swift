import XCTest
@testable import puremac

final class WorktreeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        let provisional = fm.temporaryDirectory
            .appendingPathComponent("puremac-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: provisional, withIntermediateDirectories: true)
        root = provisional.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Scan

    func testCleanPushedWorktreeIsSelectedAndMainIsNeverOffered() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "feature", at: root.appendingPathComponent("work/app-feature"))
        try git(wt, "push", "-u", "origin", "feature")

        let scan = scanRoots([root.appendingPathComponent("work").path, repo.path])

        let paths = scan.groups.flatMap(\.items).map(\.path)
        XCTAssertEqual(paths, [wt.path])
        XCTAssertTrue(scan.groups.flatMap(\.items)[0].selected)
        XCTAssertFalse(paths.contains(repo.path))
    }

    func testDirtyWorktreeIsListedButNotSelected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "wip", at: root.appendingPathComponent("work/wip"))
        try git(wt, "push", "-u", "origin", "wip")
        try "scratch".write(to: wt.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)

        XCTAssertFalse(item.selected)
        XCTAssertEqual(item.note, "uncommitted changes")
    }

    func testUnpushedWorktreeIsNotSelected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "local-only", at: root.appendingPathComponent("work/local"))
        try "x".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "commit", "-m", "local work")

        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)

        XCTAssertFalse(item.selected)
        XCTAssertEqual(item.note, "unpushed commits")
    }

    func testLockedWorktreeIsNotSelected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "locked", at: root.appendingPathComponent("work/locked"))
        try git(wt, "push", "-u", "origin", "locked")
        try git(repo, "worktree", "lock", wt.path)

        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)

        XCTAssertFalse(item.selected)
        XCTAssertEqual(item.note, "locked")
    }

    func testRecentWorktreeIsNotSelectedWhenOlderThanThresholdApplies() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "fresh", at: root.appendingPathComponent("work/fresh"))
        try git(wt, "push", "-u", "origin", "fresh")

        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path], olderThanDays: 30)
            .groups.flatMap(\.items).first)

        XCTAssertFalse(item.selected)
        XCTAssertEqual(item.note, "recent")
    }

    func testClaudeWorktreesInsideRepoAreFoundFromParentFolder() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "agent", at: repo.appendingPathComponent(".claude/worktrees/agent"))
        try git(wt, "push", "-u", "origin", "agent")

        let paths = scanRoots([root.path]).groups.flatMap(\.items).map(\.path)

        XCTAssertEqual(paths, [wt.path])
    }

    func testWorktreeSizeExcludesNestedArtifacts() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "big", at: root.appendingPathComponent("work/big"))
        try git(wt, "push", "-u", "origin", "big")
        let modules = wt.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 512 * 1024).write(to: modules.appendingPathComponent("blob.bin"))
        let nested = ScanItem(path: wt.appendingPathComponent("node_modules").path, sizeBytes: 512 * 1024, modified: nil)

        let withArtifacts = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path], artifacts: [nested])
            .groups.flatMap(\.items).first)
        let without = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path])
            .groups.flatMap(\.items).first)

        XCTAssertLessThan(withArtifacts.sizeBytes, without.sizeBytes)
        XCTAssertGreaterThanOrEqual(without.sizeBytes - withArtifacts.sizeBytes, 512 * 1024)
    }

    func testOrphanedWorktreeDirectoryIsListedUnselected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let orphan = repo.appendingPathComponent(".claude/worktrees/ghost", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/.git/worktrees/ghost\n".write(
            to: orphan.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 4096).write(to: orphan.appendingPathComponent("file.bin"))

        let item = try XCTUnwrap(scanRoots([root.path]).groups.flatMap(\.items).first)

        XCTAssertEqual(item.path, orphan.path)
        XCTAssertFalse(item.selected)
        XCTAssertEqual(item.note, "orphaned: repository missing")
    }

    // MARK: - Removal

    func testRemoveDeletesWorktreeThroughGitAndPrunesMetadata() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "gone", at: root.appendingPathComponent("work/gone"))
        try git(wt, "push", "-u", "origin", "gone")
        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: false)

        XCTAssertEqual(out.removed, 1)
        XCTAssertTrue(out.failed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: wt.path))
        XCTAssertFalse(try git(repo, "worktree", "list", "--porcelain").contains("gone"))
        XCTAssertFalse(fm.fileExists(atPath: repo.appendingPathComponent(".git/worktrees/gone").path))
    }

    func testRemoveNeverForcesADirtyWorktree() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "dirty", at: root.appendingPathComponent("work/dirty"))
        try git(wt, "push", "-u", "origin", "dirty")
        try "precious".write(to: wt.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        var item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)
        item.selected = true  // user explicitly selected it

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: false)

        XCTAssertEqual(out.removed, 0)
        XCTAssertFalse(out.skipped.isEmpty && out.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: wt.appendingPathComponent("notes.txt").path))
    }

    func testRemoveDryRunLeavesWorktreeInPlace() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "dry", at: root.appendingPathComponent("work/dry"))
        try git(wt, "push", "-u", "origin", "dry")
        let item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: true)

        XCTAssertEqual(out.removed, 1)
        XCTAssertTrue(fm.fileExists(atPath: wt.path))
    }

    func testRemoveSkipsDetachedHeadWithCommitsOnNoBranchOrRemote() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = root.appendingPathComponent("work/detached")
        try fm.createDirectory(at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(repo, "worktree", "add", "--detach", wt.path)
        try "x".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "commit", "-m", "only here")
        var item = try XCTUnwrap(scanRoots([repo.path, root.appendingPathComponent("work").path]).groups.flatMap(\.items).first)
        item.selected = true

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: false)

        XCTAssertEqual(out.removed, 0)
        XCTAssertEqual(out.skipped.first?.reason, "detached HEAD with commits not on any branch or remote")
        XCTAssertTrue(fm.fileExists(atPath: wt.path))
    }

    func testRemoveOrphanDeletesDirectoryWhenGitFileIsAFile() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let orphan = repo.appendingPathComponent(".claude/worktrees/ghost", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/.git/worktrees/ghost\n".write(
            to: orphan.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 4096).write(to: orphan.appendingPathComponent("file.bin"))
        var item = try XCTUnwrap(scanRoots([root.path]).groups.flatMap(\.items).first)
        item.selected = true

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: false)

        XCTAssertEqual(out.removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertTrue(fm.fileExists(atPath: repo.appendingPathComponent(".git").path))
    }

    func testRemoveRefusesAMainCheckout() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let item = ScanItem(path: repo.path, sizeBytes: 1, modified: nil, selected: true)

        let out = WorktreeRemover.remove([item], ignore: try makeIgnore(), dryRun: false)

        XCTAssertEqual(out.removed, 0)
        XCTAssertTrue(fm.fileExists(atPath: repo.path))
    }

    // MARK: - Helpers

    private func scanRoots(
        _ roots: [String],
        olderThanDays: Int = 0,
        artifacts: [ScanItem] = []
    ) -> CategoryScan {
        WorktreeScanner.scan(
            roots: roots,
            olderThanDays: olderThanDays,
            ignore: (try? makeIgnore())!,
            artifacts: artifacts
        )
    }

    private func makeIgnore() throws -> IgnoreStore {
        try IgnoreStore(fileURL: root.appendingPathComponent("config/ignore"))
    }

    /// A repo whose `origin` is a local bare repo with the initial commit pushed.
    private func makeRepoWithRemote(named name: String) throws -> URL {
        let remote = root.appendingPathComponent("remotes/\(name).git", isDirectory: true)
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(remote, "init", "--bare", "-b", "main")
        try git(repo, "init", "-b", "main")
        try git(repo, "config", "user.email", "t@example.com")
        try git(repo, "config", "user.name", "T")
        try git(repo, "config", "commit.gpgsign", "false")
        try "hi".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "commit", "-m", "init")
        try git(repo, "remote", "add", "origin", remote.path)
        try git(repo, "push", "-u", "origin", "main")
        return repo
    }

    private func addWorktree(_ repo: URL, branch: String, at path: URL) throws -> URL {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(repo, "worktree", "add", "-b", branch, path.path)
        try git(path, "config", "user.email", "t@example.com")
        try git(path, "config", "user.name", "T")
        return path.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ dir: URL, _ args: String...) throws -> String {
        let result = Shell.run("/usr/bin/git", ["-C", dir.path] + args, timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(result.err)"])
        }
        return result.out
    }
}
