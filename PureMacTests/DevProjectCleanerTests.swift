import XCTest
@testable import PureMac

final class DevProjectCleanerTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        let provisional = fm.temporaryDirectory
            .appendingPathComponent("puremac-devproject-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: provisional, withIntermediateDirectories: true)
        root = provisional.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Artifacts

    func testFindsOldArtifactsAndSelectsThem() throws {
        let modules = root.appendingPathComponent("web/node_modules", isDirectory: true)
        let turbo = root.appendingPathComponent("web/.turbo", isDirectory: true)
        let source = root.appendingPathComponent("web/src", isDirectory: true)
        for dir in [modules, turbo, source] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64 * 1024).write(to: dir.appendingPathComponent("f.bin"))
        }

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])

        let artifacts = result.items.filter { $0.kind == .artifact }
        XCTAssertEqual(Set(artifacts.map(\.url.lastPathComponent)), ["node_modules", ".turbo"])
        XCTAssertTrue(artifacts.allSatisfy(\.preselected))
        XCTAssertEqual(artifacts.first?.project, "web")
    }

    func testRecentArtifactsAreListedButNotPreselected() throws {
        let modules = root.appendingPathComponent("app/node_modules", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: modules.appendingPathComponent("f.bin"))

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 30, excludedPaths: [])

        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.items[0].preselected)
    }

    func testExcludedPathsAreNeverListed() throws {
        let modules = root.appendingPathComponent("keep/node_modules", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: modules.appendingPathComponent("f.bin"))

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [root.appendingPathComponent("keep").path])

        XCTAssertTrue(result.items.isEmpty)
    }

    // MARK: - Worktrees

    func testCleanPushedWorktreeIsPreselectedAndMainIsNeverOffered() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "feature", at: root.appendingPathComponent("app-feature"))
        try git(wt, "push", "-u", "origin", "feature")

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])

        let worktrees = result.items.filter { $0.kind == .worktree }
        XCTAssertEqual(worktrees.map(\.url.path), [wt.path])
        XCTAssertTrue(worktrees[0].preselected)
        XCTAssertFalse(result.items.contains { $0.url.path == repo.path })
    }

    func testDirtyUnpushedAndLockedWorktreesAreNotPreselected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let dirty = try addWorktree(repo, branch: "dirty", at: root.appendingPathComponent("wt-dirty"))
        try git(dirty, "push", "-u", "origin", "dirty")
        try "x".write(to: dirty.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let local = try addWorktree(repo, branch: "local", at: root.appendingPathComponent("wt-local"))
        try "x".write(to: local.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(local, "add", ".")
        try git(local, "commit", "-m", "local")
        let locked = try addWorktree(repo, branch: "locked", at: root.appendingPathComponent("wt-locked"))
        try git(locked, "push", "-u", "origin", "locked")
        try git(repo, "worktree", "lock", locked.path)

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])
        let notes = Dictionary(uniqueKeysWithValues: result.items.filter { $0.kind == .worktree }
            .map { ($0.url.lastPathComponent, $0) })

        XCTAssertEqual(notes["wt-dirty"]?.note, "uncommitted changes")
        XCTAssertEqual(notes["wt-local"]?.note, "unpushed commits")
        XCTAssertEqual(notes["wt-locked"]?.note, "locked")
        XCTAssertTrue(notes.values.allSatisfy { !$0.preselected })
    }

    func testClaudeWorktreeInsideRepoIsFoundAndOrphanIsListedUnselected() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "agent", at: repo.appendingPathComponent(".claude/worktrees/agent"))
        try git(wt, "push", "-u", "origin", "agent")
        let orphan = repo.appendingPathComponent(".orc/ghost", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/.git/worktrees/ghost\n".write(
            to: orphan.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])

        XCTAssertEqual(result.items.first { $0.kind == .worktree }?.url.path, wt.path)
        let orphaned = try XCTUnwrap(result.items.first { $0.kind == .orphanedWorktree })
        XCTAssertEqual(orphaned.url.path, orphan.resolvingSymlinksInPath().path)
        XCTAssertFalse(orphaned.preselected)
    }

    func testWorktreeSizeExcludesNestedArtifacts() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "big", at: root.appendingPathComponent("wt-big"))
        try git(wt, "push", "-u", "origin", "big")
        let modules = wt.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 512 * 1024).write(to: modules.appendingPathComponent("blob.bin"))

        let result = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])

        let artifact = try XCTUnwrap(result.items.first { $0.kind == .artifact })
        let worktree = try XCTUnwrap(result.items.first { $0.kind == .worktree })
        XCTAssertGreaterThanOrEqual(artifact.size, 512 * 1024)
        XCTAssertLessThan(worktree.size, artifact.size)
    }

    // MARK: - Removal

    func testRemoveWorktreeUsesGitAndPrunesMetadata() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "gone", at: root.appendingPathComponent("wt-gone"))
        try git(wt, "push", "-u", "origin", "gone")
        let item = try XCTUnwrap(DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])
            .items.first { $0.kind == .worktree })

        let out = DevProjectCleaner.remove([item], excludedPaths: [])

        XCTAssertEqual(out.removed, 1)
        XCTAssertTrue(out.failed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: wt.path))
        XCTAssertFalse(fm.fileExists(atPath: repo.appendingPathComponent(".git/worktrees/wt-gone").path))
    }

    func testRemoveNeverForcesADirtyWorktree() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = try addWorktree(repo, branch: "dirty", at: root.appendingPathComponent("wt-dirty"))
        try git(wt, "push", "-u", "origin", "dirty")
        try "precious".write(to: wt.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let item = try XCTUnwrap(DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])
            .items.first { $0.kind == .worktree })

        let out = DevProjectCleaner.remove([item], excludedPaths: [])

        XCTAssertEqual(out.removed, 0)
        XCTAssertFalse(out.failed.isEmpty && out.skipped.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: wt.appendingPathComponent("n.txt").path))
    }

    func testRemoveSkipsDetachedHeadWithCommitsOnNoBranchOrRemote() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let wt = root.appendingPathComponent("wt-detached")
        try git(repo, "worktree", "add", "--detach", wt.path)
        try "x".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "commit", "-m", "only here")
        let item = try XCTUnwrap(DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: [])
            .items.first { $0.kind == .worktree })

        let out = DevProjectCleaner.remove([item], excludedPaths: [])

        XCTAssertEqual(out.removed, 0)
        XCTAssertTrue(fm.fileExists(atPath: wt.path))
    }

    func testRemoveArtifactAndOrphanDeleteDirectories() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let modules = repo.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: modules.appendingPathComponent("f.bin"))
        let orphan = repo.appendingPathComponent(".claude/worktrees/ghost", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/.git/worktrees/ghost\n".write(
            to: orphan.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let items = DevProjectCleaner.scan(folder: root, olderThanDays: 0, excludedPaths: []).items

        let out = DevProjectCleaner.remove(items, excludedPaths: [])

        XCTAssertEqual(out.removed, 2)
        XCTAssertFalse(fm.fileExists(atPath: modules.path))
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertTrue(fm.fileExists(atPath: repo.appendingPathComponent(".git").path))
    }

    func testRemoveRefusesAMainCheckoutAndExcludedPaths() throws {
        let repo = try makeRepoWithRemote(named: "app")
        let fake = DevProjectItem(url: repo, kind: .worktree, project: "app", size: 1, modified: nil, note: nil, preselected: true)

        let out = DevProjectCleaner.remove([fake], excludedPaths: [])
        XCTAssertEqual(out.removed, 0)
        XCTAssertTrue(fm.fileExists(atPath: repo.path))

        let modules = root.appendingPathComponent("x/node_modules", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        let artifact = DevProjectItem(url: modules, kind: .artifact, project: "x", size: 1, modified: nil, note: nil, preselected: true)
        let excluded = DevProjectCleaner.remove([artifact], excludedPaths: [root.appendingPathComponent("x").path])
        XCTAssertEqual(excluded.removed, 0)
        XCTAssertTrue(fm.fileExists(atPath: modules.path))
    }

    func testRejectsHomeAndSystemFoldersAsScanRoots() {
        XCTAssertFalse(DevProjectCleaner.isValidScanRoot(URL(fileURLWithPath: NSHomeDirectory())))
        XCTAssertFalse(DevProjectCleaner.isValidScanRoot(URL(fileURLWithPath: "/System")))
        XCTAssertFalse(DevProjectCleaner.isValidScanRoot(URL(fileURLWithPath: NSHomeDirectory() + "/Library")))
        XCTAssertTrue(DevProjectCleaner.isValidScanRoot(root))
    }

    // MARK: - Helpers

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
        return path.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ dir: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(String(decoding: errData, as: UTF8.self))"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
