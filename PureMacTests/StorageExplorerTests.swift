import Darwin
import XCTest
@testable import PureMac

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

    @MainActor
    func testBackRestoresParentAndRescanRefreshesTheSnapshot() async throws {
        let nested = temporaryRoot.appendingPathComponent("Nested", isDirectory: true)
        let childFile = nested.appendingPathComponent("File")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: childFile)
        let model = SpaceExplorerViewModel()
        model.inspect(temporaryRoot)
        await model.scanTask?.value
        let entry = try XCTUnwrap(model.result?.entries.first)
        model.rememberScrollAnchor(entry.url, in: temporaryRoot.standardizedFileURL)
        model.open(entry)
        await model.scanTask?.value
        XCTAssertEqual(model.result?.rootURL, nested.standardizedFileURL)
        let newFile = temporaryRoot.appendingPathComponent("Added")
        try Data("later".utf8).write(to: newFile)

        model.goBack()

        XCTAssertEqual(model.result?.entries.map(\.name), ["Nested"])
        XCTAssertEqual(model.selectedEntry, entry.url)
        XCTAssertEqual(model.scrollAnchor, entry.url)
        XCTAssertFalse(model.canGoBack)
        model.rescan()
        await model.scanTask?.value
        XCTAssertEqual(Set(model.result?.entries.map(\.name) ?? []), ["Nested", "Added"])
    }

    @MainActor
    func testNameFilterUsesOnlyImmediateScannedEntriesAndPreservesSizeOrder() async throws {
        let larger = temporaryRoot.appendingPathComponent("Café archive.mov")
        let smaller = temporaryRoot.appendingPathComponent("CAFE notes.txt")
        let other = temporaryRoot.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 250_000).write(to: larger)
        try Data("note".utf8).write(to: smaller)
        try Data("nested".utf8).write(to: other.appendingPathComponent("cafe private"))
        let model = SpaceExplorerViewModel()
        model.inspect(temporaryRoot)
        await model.scanTask?.value
        let scannedOrder = try XCTUnwrap(model.result).entries.map(\.name)
        try Data("new".utf8).write(to: temporaryRoot.appendingPathComponent("cafe added"))

        model.nameFilter = "  cafe  "
        XCTAssertEqual(model.filteredEntries.map(\.name), ["Café archive.mov", "CAFE notes.txt"])
        model.nameFilter = "unmatched"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        model.nameFilter = " "
        XCTAssertEqual(model.filteredEntries.map(\.name), scannedOrder)
        model.nameFilter = "added"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        model.rescan()
        await model.scanTask?.value
        XCTAssertEqual(model.filteredEntries.map(\.name), ["cafe added"])
    }

    @MainActor
    func testBackRestoresFilterAndChartRevealsHiddenEntry() async throws {
        let nested = temporaryRoot.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("txt".utf8).write(to: temporaryRoot.appendingPathComponent("Notes"))
        let model = SpaceExplorerViewModel()
        model.inspect(temporaryRoot)
        await model.scanTask?.value
        let original = try XCTUnwrap(model.result)
        let other = try XCTUnwrap(original.entries.first { $0.name == "Notes" })
        model.nameFilter = "medi"
        let media = try XCTUnwrap(model.filteredEntries.first)
        model.rememberScrollAnchor(media.url, in: original.rootURL)
        model.open(media)
        await model.scanTask?.value
        XCTAssertTrue(model.nameFilter.isEmpty)

        model.goBack()
        XCTAssertEqual(model.nameFilter, "medi")
        XCTAssertEqual(model.filteredEntries.map(\.url), [media.url])
        XCTAssertEqual(model.scrollAnchor, media.url)
        model.select(media)
        XCTAssertEqual(model.nameFilter, "medi")
        model.select(other)
        XCTAssertTrue(model.nameFilter.isEmpty)
        XCTAssertEqual(model.selectedEntry, other.url)
        XCTAssertTrue(model.filteredEntries.contains(other))
    }

    @MainActor
    func testCancelledChildCannotReplaceRestoredParent() async throws {
        let nested = temporaryRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let model = SpaceExplorerViewModel()
        model.inspect(temporaryRoot)
        await model.scanTask?.value
        model.open(try XCTUnwrap(model.result?.entries.first))
        let childTask = model.scanTask
        model.goBack()
        await childTask?.value
        XCTAssertEqual(model.currentURL, temporaryRoot.standardizedFileURL)
        XCTAssertEqual(model.result?.rootURL, temporaryRoot.standardizedFileURL)
        XCTAssertNil(model.progress)
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

    func testDirectorySizeCountsHardLinksOnceAndRespectsHiddenFileScope() throws {
        let original = temporaryRoot.appendingPathComponent("original")
        let link = temporaryRoot.appendingPathComponent("linked")
        let hidden = temporaryRoot.appendingPathComponent(".hidden")
        try Data(repeating: 1, count: 131_072).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        try Data(repeating: 2, count: 65_536).write(to: hidden)
        let originalBytes = try allocatedBytes(at: original)
        let hiddenBytes = try allocatedBytes(at: hidden)

        XCTAssertEqual(FileSizeCalculator.size(of: temporaryRoot), originalBytes)
        XCTAssertEqual(FileSizeCalculator.directorySize(of: temporaryRoot, includeHidden: true), originalBytes + hiddenBytes)
    }

    func testFullClonesStayVisibleAndShareAnAllocationWhileModifiedClonesAreMeasuredSeparately() async throws {
        let original = temporaryRoot.appendingPathComponent("a-original")
        let clone = temporaryRoot.appendingPathComponent("b-clone")
        let modified = temporaryRoot.appendingPathComponent("c-modified")
        let hardLink = temporaryRoot.appendingPathComponent("d-link")
        try Data(repeating: 0x41, count: 262_144).write(to: original)
        for destination in [clone, modified] {
            let status = clonefile(original.path, destination.path, 0)
            if status != 0 && errno == ENOTSUP {
                throw XCTSkip("This test requires a filesystem with clone support")
            }
            XCTAssertEqual(status, 0)
        }
        let writer = try FileHandle(forWritingTo: modified)
        try writer.write(contentsOf: Data([0x42]))
        try writer.close()
        try FileManager.default.linkItem(at: clone, to: hardLink)
        let expected = try allocatedBytes(at: original) + allocatedBytes(at: modified)

        XCTAssertEqual(FileSizeCalculator.directorySize(of: temporaryRoot), expected)
        let result = try await StorageExplorer().scan(at: temporaryRoot)
        XCTAssertEqual(result.totalAllocatedSize, expected)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(Set(result.entries.map(\.name)), Set([original, clone, modified].map(\.lastPathComponent)))
        XCTAssertEqual(result.entries.first { $0.name == clone.lastPathComponent }?.allocatedSize, 0)
    }

    func testCloneWithAnIndependentResourceForkKeepsItsAdditionalAllocation() async throws {
        let original = temporaryRoot.appendingPathComponent("a-original")
        let clone = temporaryRoot.appendingPathComponent("b-clone")
        try Data(repeating: 0x41, count: 65_536).write(to: original)
        let status = clonefile(original.path, clone.path, 0)
        if status != 0 && errno == ENOTSUP {
            throw XCTSkip("This test requires a filesystem with clone support")
        }
        XCTAssertEqual(status, 0)
        let resourceFork = clone.appendingPathComponent("..namedfork/rsrc")
        try Data(repeating: 0x42, count: 262_144).write(to: resourceFork)
        let originalBytes = try allocatedBytes(at: original)
        let forkBytes = try allocatedBytes(at: resourceFork)
        XCTAssertGreaterThan(forkBytes, 0)

        XCTAssertEqual(FileSizeCalculator.directorySize(of: temporaryRoot), originalBytes + forkBytes)
        let result = try await StorageExplorer().scan(at: temporaryRoot)
        XCTAssertEqual(result.entries.first { $0.name == clone.lastPathComponent }?.allocatedSize, forkBytes)
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int64(info.st_blocks) * 512
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
