import Darwin
import XCTest
@testable import PureMac

final class AppleStorageServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("PureMac-AppleStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testEmptyAndMissingFoldersHaveDifferentStates() async throws {
        let missing = root.appendingPathComponent("Missing")
        let items = try await AppleStorageService.scan(locations: [location(root), location(missing)])

        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].allocatedBytes, 0)
        XCTAssertEqual(items[1].status, .notPresent)
        XCTAssertNil(items[1].allocatedBytes)
    }

    func testMeasuresAllocatedBytesAndCountsHardLinksOnce() async throws {
        let file = root.appendingPathComponent("payload")
        try Data(repeating: 0x31, count: 32_768).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hard-link"))
        let sparse = root.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()
        var fileStat = stat()
        var sparseStat = stat()
        XCTAssertEqual(lstat(file.path, &fileStat), 0)
        XCTAssertEqual(lstat(sparse.path, &sparseStat), 0)

        let item = try await scan(root)

        XCTAssertEqual(item.status, .complete)
        XCTAssertEqual(item.allocatedBytes, Int64(fileStat.st_blocks + sparseStat.st_blocks) * 512)
        XCTAssertLessThan(try XCTUnwrap(item.allocatedBytes), 64 * 1_024 * 1_024)
        XCTAssertEqual(item.scannedCount, 3)
    }

    func testSymlinksAndPackagesAreSkippedAndReportedAsPartial() async throws {
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 131_072).write(to: outside.appendingPathComponent("payload"))
        let scanned = root.appendingPathComponent("Scanned")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scanned.appendingPathComponent("link"), withDestinationURL: outside)
        let package = scanned.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 65_536).write(to: package.appendingPathComponent("payload"))

        let item = try await scan(scanned)

        XCTAssertEqual(item.status, .partial)
        XCTAssertEqual(item.skippedCount, 2)
        XCTAssertEqual(item.allocatedBytes, 0)
    }

    func testSymbolicLinkRootAndAncestorAreUnavailable() async throws {
        let actual = root.appendingPathComponent("Actual/Nested")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual.deletingLastPathComponent())

        for url in [link, link.appendingPathComponent("Nested")] {
            let item = try await scan(url)
            XCTAssertEqual(item.status, .unavailable)
            XCTAssertNil(item.allocatedBytes)
            XCTAssertEqual(item.skippedCount, 1)
        }
    }

    func testKnownModelPackagesAreMeasuredWithoutOpeningOtherPackages() async throws {
        let model = root.appendingPathComponent("model.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let payload = model.appendingPathComponent("weights.bin")
        try Data(repeating: 0x32, count: 65_536).write(to: payload)
        var metadata = stat()
        XCTAssertEqual(lstat(payload.path, &metadata), 0)

        let items = try await AppleStorageService.scan(locations: [AppleStorageLocation(kind: .intelligenceModels, url: root)])
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.status, .complete)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(item.allocatedBytes), Int64(metadata.st_blocks) * 512)
        XCTAssertEqual(item.skippedCount, 0)
    }

    func testEntryLimitProducesLowerBoundRatherThanCompleteSize() async throws {
        for index in 0..<4 {
            try Data(repeating: UInt8(index), count: 8_192).write(to: root.appendingPathComponent("\(index)"))
        }

        let items = try await AppleStorageService.scan(locations: [location(root)], maxEntriesPerLocation: 2)
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.status, .partial)
        XCTAssertTrue(item.reachedLimit)
        XCTAssertEqual(item.scannedCount, 2)
        XCTAssertNotNil(item.allocatedBytes)
    }

    func testUnreadableFolderIsUnavailableNotEmpty() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read permission-restricted fixtures") }
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, S_IRWXU) }

        let item = try await scan(locked)

        XCTAssertEqual(item.status, .unavailable)
        XCTAssertNil(item.allocatedBytes)
        XCTAssertGreaterThan(item.inaccessibleCount, 0)
    }

    func testCancellationPropagatesInsteadOfReturningPartialSuccess() async throws {
        let locations = [location(root)]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleStorageService.scan(locations: locations)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func location(_ url: URL) -> AppleStorageLocation {
        AppleStorageLocation(kind: .deviceBackups, url: url)
    }

    private func scan(_ url: URL) async throws -> AppleStorageItem {
        let items = try await AppleStorageService.scan(locations: [location(url)])
        return try XCTUnwrap(items.first)
    }
}
