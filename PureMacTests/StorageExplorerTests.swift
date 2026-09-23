import Darwin
import XCTest
@testable import Qpure

final class StorageExplorerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacStorageExplorerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testScanSortsImmediateEntriesAndAggregatesDescendants() async throws {
        let nested = temporaryRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1_200_000)
            .write(to: nested.appendingPathComponent("large.bin"), options: .withoutOverwriting)
        try Data(repeating: 0x42, count: 8_000)
            .write(to: temporaryRoot.appendingPathComponent("small.bin"), options: .withoutOverwriting)

        let result = try await StorageExplorer().scan(at: temporaryRoot)

        XCTAssertEqual(result.rootURL, temporaryRoot.standardizedFileURL)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.directoryCount, 1)
        XCTAssertEqual(result.entries.map(\.name), ["Nested", "small.bin"])
        XCTAssertEqual(result.entries.reduce(Int64(0)) { $0 + $1.allocatedSize }, result.totalAllocatedSize)
        XCTAssertGreaterThan(result.totalAllocatedSize, 0)
        XCTAssertFalse(result.isPartial)
    }

    func testScanMeasuresPackagesAndSkipsSymbolicLinksAndDuplicateHardLinks() async throws {
        let source = temporaryRoot.appendingPathComponent("source.bin")
        let hardLink = temporaryRoot.appendingPathComponent("source-hardlink.bin")
        try Data(repeating: 0x4A, count: 512_000).write(to: source, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: source, to: hardLink)

        let outside = temporaryRoot.deletingLastPathComponent()
            .appendingPathComponent("PureMacStorageExplorerOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(repeating: 0x7F, count: 2_000_000)
            .write(to: outside.appendingPathComponent("outside.bin"), options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(
            at: temporaryRoot.appendingPathComponent("linked-outside"),
            withDestinationURL: outside
        )

        let package = temporaryRoot.appendingPathComponent("Excluded.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 1_000_000)
            .write(to: contents.appendingPathComponent("payload.bin"), options: .withoutOverwriting)

        let result = try await StorageExplorer().scan(at: temporaryRoot)

        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.directoryCount, 2)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries.contains { $0.name == "Excluded.app" })
        XCTAssertEqual(result.entries.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(result.entries.filter { $0.kind == .file && $0.allocatedSize > 0 }.count, 1)
        let packageEntry = try XCTUnwrap(result.entries.first { $0.kind == .package })
        XCTAssertGreaterThan(packageEntry.allocatedSize, 0)
        XCTAssertFalse(packageEntry.isDirectory)
        XCTAssertTrue(packageEntry.isPackage)
        XCTAssertTrue(result.isPartial)
    }

    func testScanReportsAllocatedSizeInsteadOfLogicalSizeForSparseFile() async throws {
        let sparseFile = temporaryRoot.appendingPathComponent("sparse.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparseFile)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()

        let result = try await StorageExplorer().scan(at: temporaryRoot)
        let entry = try XCTUnwrap(result.entries.first)

        XCTAssertEqual(entry.allocatedSize, result.totalAllocatedSize)
        XCTAssertLessThan(entry.allocatedSize, 64 * 1_024 * 1_024)
        XCTAssertEqual(result.fileCount, 1)
    }

    func testScanMarksUnreadableDirectoryAsPartial() async throws {
        let locked = temporaryRoot.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 4_096)
            .write(to: locked.appendingPathComponent("private.bin"), options: .withoutOverwriting)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, S_IRWXU) }

        let result = try await StorageExplorer().scan(at: temporaryRoot)

        XCTAssertEqual(result.inaccessibleCount, 1)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.entries.first?.inaccessibleCount, 1)
    }

    func testCancelledTaskStopsTraversal() async throws {
        for index in 0..<100 {
            let url = temporaryRoot.appendingPathComponent("file-\(index).bin")
            try Data(repeating: UInt8(index % 255), count: 4_096).write(to: url, options: .withoutOverwriting)
        }

        let explorer = StorageExplorer()
        let task = Task {
            try await explorer.scan(at: temporaryRoot)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected scan cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testRejectsSymbolicLinkAsScanRoot() async throws {
        let target = temporaryRoot.appendingPathComponent("Target", isDirectory: true)
        let link = temporaryRoot.appendingPathComponent("Target Link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            _ = try await StorageExplorer().scan(at: link)
            XCTFail("Expected symbolic-link rejection")
        } catch let error as StorageExplorerError {
            XCTAssertEqual(error, .symbolicLink(link.standardizedFileURL.path))
        }
    }
}
