import Foundation
import Darwin
import XCTest
@testable import PureMac

final class DuplicateFinderTests: XCTestCase {
    private var temporaryFolders: [URL] = []

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders = []
        try super.tearDownWithError()
    }

    @MainActor
    func testKeepThisCopyRevalidatesAndNeverSelectsTheNewKeeper() async throws {
        let folder = try makeTemporaryFolder()
        for name in ["A", "B", "C"] {
            try write("duplicate", to: folder.appendingPathComponent(name))
        }
        let recorder = URLRecorder()
        let model = DuplicateFinderViewModel(finder: DuplicateFinder(trashHandler: { recorder.append($0) }))
        model.startScan(folder)
        await model.scanTask?.value
        XCTAssertEqual(model.result?.folder, folder.standardizedFileURL)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        let initial = try XCTUnwrap(model.result?.groups.first)
        let newKeeper = try XCTUnwrap(initial.files.last)
        model.toggleGroupSelection(initial)
        model.keep(newKeeper.url, in: initial.id)
        let updated = try XCTUnwrap(model.result?.groups.first)
        XCTAssertEqual(updated.keeper, newKeeper)
        XCTAssertFalse(model.selectedIDs.contains(newKeeper.url))
        XCTAssertFalse(model.selectedIDs.contains(initial.keeper.url))
        model.selectAllCopies()
        XCTAssertEqual(model.selectedIDs, Set(initial.files.map(\.url)).subtracting([newKeeper.url]))

        try write("changed after scan", to: newKeeper.url)
        model.moveSelectedToTrash()
        await model.trashTask?.value
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertNotNil(model.actionMessage)
        model.leaveReview()
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertEqual(model.result?.groups.first?.keeper, newKeeper)
    }

    @MainActor
    func testChangingFoldersClearsOldSelectionAndKeeper() async throws {
        let first = try makeTemporaryFolder()
        let second = try makeTemporaryFolder()
        for folder in [first, second] {
            try write("duplicate", to: folder.appendingPathComponent("A"))
            try write("duplicate", to: folder.appendingPathComponent("B"))
        }
        let model = DuplicateFinderViewModel()
        model.startScan(first)
        await model.scanTask?.value
        let initial = try XCTUnwrap(model.result?.groups.first)
        model.keep(try XCTUnwrap(initial.files.last).url, in: initial.id)
        model.selectAllCopies()

        model.startScan(second)
        await model.scanTask?.value

        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertEqual(model.result?.folder, second.standardizedFileURL)
        XCTAssertTrue(model.result?.groups.first?.files.allSatisfy {
            $0.url.deletingLastPathComponent() == second.standardizedFileURL
        } == true)
    }

    func testScanGroupsOnlyByteIdenticalFiles() async throws {
        let folder = try makeTemporaryFolder()
        try write("same payload", to: folder.appendingPathComponent("A.txt"))
        try write("same payload", to: folder.appendingPathComponent("B.txt"))
        try write("different!!!", to: folder.appendingPathComponent("C.txt"))

        let result = try await DuplicateFinder().scan(folder: folder)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.url.lastPathComponent)), ["A.txt", "B.txt"])
        XCTAssertEqual(result.groups[0].reclaimableSize, 12)
        XCTAssertEqual(result.filesInspected, 3)
    }

    func testScanDoesNotCountHardLinksAsRecoverableCopies() async throws {
        let folder = try makeTemporaryFolder()
        let original = folder.appendingPathComponent("original.bin")
        let hardLink = folder.appendingPathComponent("hard-link.bin")
        let independentCopy = folder.appendingPathComponent("copy.bin")
        try write("identical hard-link payload", to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        try write("identical hard-link payload", to: independentCopy)

        let result = try await DuplicateFinder().scan(folder: folder)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].files.count, 2)
        XCTAssertEqual(result.skippedFiles.filter { $0.reason == .hardLink }.count, 1)
        XCTAssertEqual(result.groups[0].reclaimableSize, 27)
    }

    func testScanSkipsSymbolicLinksPackagesAndCloudPlaceholders() async throws {
        let folder = try makeTemporaryFolder()
        let source = folder.appendingPathComponent("source.data")
        let copy = folder.appendingPathComponent("copy.data")
        let symlink = folder.appendingPathComponent("linked.data")
        let package = folder.appendingPathComponent("Archive.app", isDirectory: true)
        try write("duplicate", to: source)
        try write("duplicate", to: copy)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try write("duplicate", to: package.appendingPathComponent("hidden.data"))
        try write("duplicate", to: folder.appendingPathComponent("pending.icloud"))

        let result = try await DuplicateFinder().scan(folder: folder)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.url.lastPathComponent)), ["source.data", "copy.data"])
        XCTAssertTrue(result.skippedFiles.contains { $0.url == symlink && $0.reason == .symbolicLink })
        XCTAssertTrue(result.skippedFiles.contains { $0.url == package && $0.reason == .package })
        XCTAssertTrue(result.skippedFiles.contains { $0.url.lastPathComponent == "pending.icloud" && $0.reason == .cloudPlaceholder })
        XCTAssertFalse(result.groups.flatMap(\.files).contains { $0.url.path.contains("Archive.app/") })
    }

    func testDatalessFileFlagIsRecognizedWithoutReadingFileContents() {
        XCTAssertTrue(DuplicateFinder.isDatalessFile(flags: UInt32(SF_DATALESS)))
        XCTAssertTrue(DuplicateFinder.isDatalessFile(flags: UInt32(SF_DATALESS) | UInt32(UF_HIDDEN)))
        XCTAssertFalse(DuplicateFinder.isDatalessFile(flags: UInt32(UF_HIDDEN)))
    }

    func testMutationAfterScanStopsTrashAction() async throws {
        let folder = try makeTemporaryFolder()
        let first = folder.appendingPathComponent("first.txt")
        let second = folder.appendingPathComponent("second.txt")
        try write("same bytes", to: first)
        try write("same bytes", to: second)
        let result = try await DuplicateFinder().scan(folder: folder)
        let group = try XCTUnwrap(result.groups.first)
        let selected = try XCTUnwrap(group.files.first { $0.url != group.keeper.url })
        try write("new content", to: selected.url)
        let finder = DuplicateFinder(trashHandler: { _ in
            XCTFail("Trash must not be called after a file changes")
        })

        do {
            _ = try await finder.moveToTrash(group: group, selectedIDs: [selected.url])
            XCTFail("Expected changed-file validation to fail")
        } catch let error as DuplicateFinderError {
            guard case .fileChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
    }

    func testChangedKeeperStopsTrashAction() async throws {
        let folder = try makeTemporaryFolder()
        try write("keeper bytes", to: folder.appendingPathComponent("first.txt"))
        try write("keeper bytes", to: folder.appendingPathComponent("second.txt"))
        let result = try await DuplicateFinder().scan(folder: folder)
        let group = try XCTUnwrap(result.groups.first)
        let selected = try XCTUnwrap(group.files.first { $0.url != group.keeper.url })
        try write("keeper moved", to: group.keeper.url)
        let finder = DuplicateFinder(trashHandler: { _ in
            XCTFail("Trash must not be called when the keeper changes")
        })

        do {
            _ = try await finder.moveToTrash(group: group, selectedIDs: [selected.url])
            XCTFail("Expected keeper validation to fail")
        } catch let error as DuplicateFinderError {
            guard case .keeperChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
    }

    func testKeeperCannotBeSelectedForTrash() async throws {
        let folder = try makeTemporaryFolder()
        try write("protected", to: folder.appendingPathComponent("first.txt"))
        try write("protected", to: folder.appendingPathComponent("second.txt"))
        let result = try await DuplicateFinder().scan(folder: folder)
        let group = try XCTUnwrap(result.groups.first)
        let finder = DuplicateFinder(trashHandler: { _ in
            XCTFail("Trash must not be called for the protected copy")
        })

        do {
            _ = try await finder.moveToTrash(group: group, selectedIDs: [group.keeper.url])
            XCTFail("Expected protected-copy validation to fail")
        } catch let error as DuplicateFinderError {
            guard case .invalidSelection(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, group.keeper.url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
    }

    func testPathReplacementImmediatelyBeforeTrashIsRejected() async throws {
        let folder = try makeTemporaryFolder()
        try write("race-safe", to: folder.appendingPathComponent("first.txt"))
        try write("race-safe", to: folder.appendingPathComponent("second.txt"))
        let result = try await DuplicateFinder().scan(folder: folder)
        let group = try XCTUnwrap(result.groups.first)
        let selected = try XCTUnwrap(group.files.first { $0.url != group.keeper.url })
        let finder = DuplicateFinder(
            trashHandler: { _ in XCTFail("A replaced path must never reach Trash") },
            preTrashHandler: { url in try Data("intruder".utf8).write(to: url, options: .atomic) }
        )

        let report = try await finder.moveToTrash(group: group, selectedIDs: [selected.url])

        XCTAssertTrue(report.trashedFiles.isEmpty)
        XCTAssertEqual(report.failures.map(\.url), [selected.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
    }

    func testCancelledBatchReportsCompletedMoveAndKeepsChosenCopy() async throws {
        let folder = try makeTemporaryFolder()
        for name in ["A", "B", "C"] {
            try write("same bytes", to: folder.appendingPathComponent(name))
        }
        let result = try await DuplicateFinder().scan(folder: folder)
        let initial = try XCTUnwrap(result.groups.first)
        let selectedKeeper = try XCTUnwrap(initial.files.last)
        let group = try XCTUnwrap(initial.keeping(selectedKeeper.url))
        let recorder = URLRecorder()
        let finder = DuplicateFinder(trashHandler: { url in
            recorder.append(url)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let report = try await Task {
            try await finder.moveToTrash(group: group, selectedIDs: Set(group.files.dropFirst().map(\.url)))
        }.value

        XCTAssertEqual(recorder.urls, [initial.keeper.url])
        XCTAssertEqual(report.trashedFiles.map(\.url), recorder.urls)
        XCTAssertFalse(recorder.urls.contains(selectedKeeper.url))
    }

    func testValidActionUsesTrashHandlerAndKeepsOriginal() async throws {
        let folder = try makeTemporaryFolder()
        try write("safe copy", to: folder.appendingPathComponent("first.txt"))
        try write("safe copy", to: folder.appendingPathComponent("second.txt"))
        let result = try await DuplicateFinder().scan(folder: folder)
        let group = try XCTUnwrap(result.groups.first)
        let selected = try XCTUnwrap(group.files.first { $0.url != group.keeper.url })
        let recorder = URLRecorder()
        let finder = DuplicateFinder(trashHandler: { recorder.append($0) })

        let report = try await finder.moveToTrash(group: group, selectedIDs: [selected.url])

        XCTAssertEqual(report.trashedFiles.map(\.url), [selected.url])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(recorder.urls, [selected.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.keeper.url.path))
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-DuplicateFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryFolders.append(folder)
        return folder
    }

    private func write(_ string: String, to url: URL) throws {
        try XCTUnwrap(string.data(using: .utf8)).write(to: url, options: .atomic)
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}
