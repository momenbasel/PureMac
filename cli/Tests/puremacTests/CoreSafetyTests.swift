import XCTest
@testable import puremac

final class CoreSafetyTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        let provisionalRoot = fileManager.temporaryDirectory
            .appendingPathComponent("puremac-core-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: provisionalRoot, withIntermediateDirectories: true)
        root = provisionalRoot.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testIgnoredDescendantProtectsParentArtifact() throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        let artifact = project.appendingPathComponent("node_modules", isDirectory: true)
        let removable = project.appendingPathComponent("target", isDirectory: true)
        let keep = artifact.appendingPathComponent("keep.bin")
        try fileManager.createDirectory(at: artifact, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: removable, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: keep)
        try Data(repeating: 2, count: 4096).write(to: removable.appendingPathComponent("cache.bin"))
        var ignore = try makeIgnoreStore()
        _ = try ignore.add(keep.path)

        let verdict = Safety.canRemove(artifact.path, ignore: ignore)
        let scan = Purger.scan(roots: [project.path], olderThanDays: 0, ignore: ignore)

        XCTAssertFalse(verdict.ok)
        XCTAssertEqual(verdict.reason, "ignored")
        XCTAssertEqual(
            scan.groups.flatMap(\.items).map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
            [removable.resolvingSymlinksInPath().path]
        )
        XCTAssertTrue(fileManager.fileExists(atPath: keep.path))
    }

    func testCleanerRefusesSymlinkAtAnyPathComponent() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let victim = target.appendingPathComponent("victim.bin")
        let link = root.appendingPathComponent("link", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: victim)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedVictim = link.appendingPathComponent("victim.bin")
        let item = ScanItem(path: linkedVictim.path, sizeBytes: 4096, modified: nil)

        let outcome = Cleaner.remove([item], ignore: try makeIgnoreStore(), dryRun: false)

        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.skipped.first?.reason, "symlink")
        XCTAssertTrue(fileManager.fileExists(atPath: victim.path))
    }

    func testCleanerRefusesPathReplacedAfterScan() throws {
        let artifact = root.appendingPathComponent("node_modules", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try fileManager.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4096).write(to: artifact.appendingPathComponent("old.bin"))
        let item = ScanItem(path: artifact.path, sizeBytes: 4096, modified: nil)
        try fileManager.createDirectory(at: replacement, withIntermediateDirectories: true)
        let marker = replacement.appendingPathComponent("replacement.bin")
        try Data(repeating: 4, count: 4096).write(to: marker)
        try fileManager.removeItem(at: artifact)
        try fileManager.moveItem(at: replacement, to: artifact)

        let outcome = Cleaner.remove([item], ignore: try makeIgnoreStore(), dryRun: false)

        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.skipped.first?.reason, "changed since scan")
        XCTAssertTrue(fileManager.fileExists(atPath: artifact.appendingPathComponent("replacement.bin").path))
    }

    private func makeFolder(files: Int) throws -> URL {
        let folder = root.appendingPathComponent("folder-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data(repeating: 6, count: 4096).write(to: folder.appendingPathComponent("file-\(index).bin"))
        }
        return folder
    }

    func testMeasureWithoutACancelClosureStaysComplete() throws {
        let folder = try makeFolder(files: 30)

        let measured = DirSizer.measure(of: folder.path)

        XCTAssertEqual(measured.status, .complete)
        XCTAssertEqual(measured.skippedEntries, 0)
        XCTAssertGreaterThanOrEqual(measured.bytes, 30 * 4096)
        XCTAssertEqual(DirSizer.measure(of: folder.path, isCancelled: { false }).bytes, measured.bytes)
    }

    func testMeasureStopsInsideTheWalkWhenCancelledAndIsNeverComplete() throws {
        let folder = try makeFolder(files: 60)
        var checks = 0

        let measured = DirSizer.measure(of: folder.path, isCancelled: {
            checks += 1
            return checks > 5
        })

        XCTAssertEqual(measured.status, .partial)
        XCTAssertGreaterThan(measured.skippedEntries, 0)
        XCTAssertLessThan(measured.bytes, 60 * 4096)
        XCTAssertLessThan(checks, 20)
    }

    func testCleanerAccountsFreshMeasuredBytes() throws {
        let file = root.appendingPathComponent("cache.bin")
        try Data(repeating: 5, count: 8192).write(to: file)
        let item = ScanItem(path: file.path, sizeBytes: 99_999_999, modified: nil)
        let measured = DirSizer.measure(of: file.path)

        let outcome = Cleaner.remove([item], ignore: try makeIgnoreStore(), dryRun: false)

        XCTAssertEqual(measured.status, .complete)
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.freedBytes, measured.bytes)
        XCTAssertNotEqual(outcome.freedBytes, item.sizeBytes)
        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
    }

    func testProtectedAndCloudRootsFailClosed() throws {
        let ignore = try makeIgnoreStore()

        XCTAssertFalse(Safety.canRemove("/System/Library", ignore: ignore).ok)
        XCTAssertFalse(Safety.isValidScanRoot("/System/Library").ok)
        XCTAssertTrue(Safety.isCloudOrDataless("\(Safety.home)/Library/CloudStorage/Provider/file"))
        XCTAssertFalse(Safety.isValidScanRoot("\(Safety.home)/Library/CloudStorage/Provider").ok)
    }

    func testCandidateAndRootDeduplicationPreventsDoubleCounting() throws {
        let parent = root.appendingPathComponent("project", isDirectory: true)
        let child = parent.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)

        let candidates = CategoryScanner.uniqueCandidates([
            (target: 1, path: child.path),
            (target: 0, path: parent.path),
            (target: 2, path: parent.path),
        ])
        let roots = Purger.scanRoots([child.path, parent.path, parent.path])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.path, parent.path)
        XCTAssertEqual(roots.map(\.path), [parent.path])
    }

    func testTemporaryAliasesRemainUsableButCustomSymlinksDoNot() throws {
        XCTAssertFalse(Safety.hasSymlinkComponent("/tmp/puremac-fixture"))
        XCTAssertFalse(Safety.hasSymlinkComponent("/var/folders/puremac-fixture"))
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("custom-link", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(Safety.hasSymlinkComponent(link.appendingPathComponent("child").path))
    }

    func testRelativeProjectRootNormalizesWithoutChangingProcessDirectory() throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let originalDirectory = fileManager.currentDirectoryPath

        let normalized = Safety.absolutePath("./project", currentDirectory: root.path)
        let verdict = Safety.isValidScanRoot("./project", currentDirectory: root.path)

        XCTAssertEqual(
            URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path,
            project.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(verdict.ok)
        XCTAssertEqual(fileManager.currentDirectoryPath, originalDirectory)
        XCTAssertFalse(Safety.isValidScanRoot("/private/etc").ok)
    }

    private func makeIgnoreStore() throws -> IgnoreStore {
        try IgnoreStore(fileURL: root.appendingPathComponent("config/ignore"))
    }
}
