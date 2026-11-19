import Darwin
import XCTest
@testable import PureMac

final class DeviceBackupServiceTests: XCTestCase {
    private var home: URL!
    private var backupRoot: URL { home.appendingPathComponent("Library/Application Support/MobileSync/Backup") }

    override func setUpWithError() throws {
        home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("PureMacBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    func testScanMeasuresAllocatedStorageAndListsOnlyChildFolders() async throws {
        let backup = try makeBackup("phone")
        let file = backup.appendingPathComponent("payload")
        try Data(repeating: 7, count: 8192).write(to: file)
        try FileManager.default.linkItem(at: file, to: backup.appendingPathComponent("same-storage"))
        try Data("ignore".utf8).write(to: backupRoot.appendingPathComponent("not-a-folder"))

        let result = try await service().scan()

        let item = try XCTUnwrap(result.backups.first)
        XCTAssertEqual(result.backups.count, 1)
        XCTAssertEqual(item.url, backup)
        let markerSize = try ["Manifest.plist", "Info.plist", "Status.plist", "Manifest.db"].reduce(Int64(0)) {
            try $0 + allocatedBytes(backup.appendingPathComponent($1))
        }
        XCTAssertEqual(item.allocatedSize, try allocatedBytes(backup) + allocatedBytes(file) + markerSize)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidSelectionUsesTrashAndReportsFailuresWithoutPermanentFallback() async throws {
        let first = try makeBackup("phone")
        let second = try makeBackup("tablet")
        let trash = home.appendingPathComponent("FixtureTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let instance = service { url in
            if url == second { throw POSIXError(.EACCES) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let scan = try await instance.scan()

        let result = try await instance.trash(scan.backups)

        XCTAssertEqual(result.removedPaths, [first.path])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("phone").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testNestedSymlinkRejectsEntireBackupWithoutFollowingTarget() async throws {
        let backup = try makeBackup("phone")
        let target = home.appendingPathComponent("private-data")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("linked"), withDestinationURL: target)

        let result = try await service().scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testSymlinkedBackupRootIsRejected() async throws {
        let target = home.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: backupRoot, to: target)
        try FileManager.default.createSymbolicLink(at: backupRoot, withDestinationURL: target)

        let result = try await service().scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testSymlinkedParentIsRejected() async throws {
        let library = home.appendingPathComponent("Library")
        let target = home.appendingPathComponent("MovedLibrary")
        try FileManager.default.moveItem(at: library, to: target)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: target)

        let result = try await service().scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testChangedDescendantRefusesTrash() async throws {
        let backup = try makeBackup("phone")
        let payload = backup.appendingPathComponent("payload")
        try Data("old".utf8).write(to: payload)
        let instance = service { _ in XCTFail("Changed backup must not reach Trash") }
        let scan = try await instance.scan()
        try Data("changed content".utf8).write(to: payload)

        let result = try await instance.trash(scan.backups)

        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testReplacedBackupAndAddedSymlinkRefuseTrash() async throws {
        let backup = try makeBackup("phone")
        let instance = service { _ in XCTFail("Replaced backup must not reach Trash") }
        let scan = try await instance.scan()
        let moved = home.appendingPathComponent("old-backup")
        try FileManager.default.moveItem(at: backup, to: moved)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: moved)

        let result = try await instance.trash(scan.backups)

        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testExclusionAddedAfterScanProtectsBackupAndItsContainingFolder() async throws {
        let backup = try makeBackup("phone")
        let selected = try await service().scan().backups
        let instance = DeviceBackupService(
            homeDirectory: home,
            trashHandler: { _ in XCTFail("Excluded backup must not reach Trash") },
            exclusions: { [backup.appendingPathComponent("preserve").path] }
        )

        let result = try await instance.trash(selected)
        let scan = try await instance.scan()

        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(scan.backups.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
    }

    func testBackupFromAnotherRootCannotBeTrashed() async throws {
        _ = try makeBackup("phone")
        let scan = try await service().scan()
        let instance = DeviceBackupService(
            homeDirectory: home.appendingPathComponent("another-home"),
            trashHandler: { _ in XCTFail("Foreign backup must not reach Trash") },
            exclusions: { [] }
        )

        let result = try await instance.trash(scan.backups)

        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testScanLimitNeverReturnsPartiallyMeasuredBackup() async throws {
        let backup = try makeBackup("phone")
        try Data("payload".utf8).write(to: backup.appendingPathComponent("payload"))
        let instance = DeviceBackupService(homeDirectory: home, exclusions: { [] }, maxEntries: 1)

        let result = try await instance.scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testMissingBackupRootIsEmpty() async throws {
        try FileManager.default.removeItem(at: backupRoot)

        let result = try await service().scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testUnrecognizedAndInProgressFoldersAreNotOffered() async throws {
        try FileManager.default.createDirectory(at: backupRoot.appendingPathComponent("unrecognized"), withIntermediateDirectories: true)
        let inProgress = try makeBackup("active")
        let status = try PropertyListSerialization.data(fromPropertyList: ["SnapshotState": "in-progress"], format: .binary, options: 0)
        try status.write(to: inProgress.appendingPathComponent("Status.plist"))

        let result = try await service().scan()

        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertEqual(result.issues.count, 2)
    }

    func testBackupThatBecomesActiveIsNotTrashed() async throws {
        let backup = try makeBackup("phone")
        let instance = service { _ in XCTFail("An active backup must not reach Trash") }
        let scan = try await instance.scan()
        let status = try PropertyListSerialization.data(fromPropertyList: ["SnapshotState": "in-progress"], format: .binary, options: 0)
        try status.write(to: backup.appendingPathComponent("Status.plist"))

        let result = try await instance.trash(scan.backups)

        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCancellationPreservesPartialRemovalReport() async throws {
        _ = try makeBackup("phone")
        _ = try makeBackup("tablet")
        let instance = service { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let scan = try await instance.scan()
        let task = Task { try await instance.trash(scan.backups) }

        let result = try await task.value

        XCTAssertEqual(result.removedPaths.count, 1)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("cancelled"))
    }

    private func service(trashHandler: ((URL) throws -> Void)? = nil) -> DeviceBackupService {
        DeviceBackupService(homeDirectory: home, trashHandler: trashHandler, exclusions: { [] })
    }

    private func makeBackup(_ name: String) throws -> URL {
        let url = backupRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let marker = try PropertyListSerialization.data(fromPropertyList: ["Fixture": true], format: .binary, options: 0)
        for name in ["Manifest.plist", "Info.plist"] { try marker.write(to: url.appendingPathComponent(name)) }
        let status = try PropertyListSerialization.data(fromPropertyList: ["SnapshotState": "finished"], format: .binary, options: 0)
        try status.write(to: url.appendingPathComponent("Status.plist"))
        try Data("fixture manifest".utf8).write(to: url.appendingPathComponent("Manifest.db"))
        return url
    }

    private func allocatedBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        return Int64(info.st_blocks) * 512
    }
}
