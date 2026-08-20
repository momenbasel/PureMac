import Darwin
import XCTest
@testable import PureMac

final class FileTreeScannerTests: XCTestCase {
    func testScansNormalNestedAndHiddenItemsIntoHierarchy() async throws {
        let temporaryDirectory = try TemporaryTestDirectory()
        let nestedDirectory = temporaryDirectory.url.appendingPathComponent("nested", isDirectory: true)
        let hiddenDirectory = temporaryDirectory.url.appendingPathComponent(".hidden-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: false)

        let visibleFile = temporaryDirectory.url.appendingPathComponent("visible.txt")
        let nestedFile = nestedDirectory.appendingPathComponent("child.dat")
        let hiddenFile = temporaryDirectory.url.appendingPathComponent(".hidden-file")
        let hiddenChild = hiddenDirectory.appendingPathComponent("inside.txt")
        try Data(repeating: 0x11, count: 4_096).write(to: visibleFile)
        try Data(repeating: 0x22, count: 2_048).write(to: nestedFile)
        try Data(repeating: 0x33, count: 1_024).write(to: hiddenFile)
        try Data(repeating: 0x44, count: 512).write(to: hiddenChild)

        let result = await FileTreeScanner(
            configuration: .init(maxConcurrentDirectoryReads: 2)
        ).scan(root: temporaryDirectory.url)

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(node(at: visibleFile.path, in: result.root)?.ownLogicalSize, 4_096)
        XCTAssertEqual(node(at: nestedFile.path, in: result.root)?.ownLogicalSize, 2_048)
        XCTAssertEqual(node(at: hiddenFile.path, in: result.root)?.isHidden, true)
        XCTAssertEqual(node(at: hiddenDirectory.path, in: result.root)?.isHidden, true)
        XCTAssertNotNil(node(at: hiddenChild.path, in: result.root))

        let nestedNode = try XCTUnwrap(node(at: nestedDirectory.path, in: result.root))
        XCTAssertEqual(nestedNode.children.map(\.absolutePath), [nestedFile.path])

        let countedLogicalBytes = flattened(result.root)
            .filter(\.isCountedInParentTotals)
            .reduce(Int64(0)) { $0 + $1.ownLogicalSize }
        let countedAllocatedBytes = flattened(result.root)
            .filter(\.isCountedInParentTotals)
            .reduce(Int64(0)) { $0 + $1.ownAllocatedSize }
        XCTAssertEqual(result.root.logicalSize, countedLogicalBytes)
        XCTAssertEqual(result.root.allocatedSize, countedAllocatedBytes)
    }

    func testSymbolicLinkIsRepresentedWithoutFollowingItsTarget() async throws {
        let temporaryDirectory = try TemporaryTestDirectory()
        let scanRoot = temporaryDirectory.url.appendingPathComponent("scan-root", isDirectory: true)
        let outsideDirectory = temporaryDirectory.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)

        let outsideFile = outsideDirectory.appendingPathComponent("large-target.dat")
        try Data(repeating: 0x55, count: 1_048_576).write(to: outsideFile)
        let link = scanRoot.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        let result = await FileTreeScanner().scan(root: scanRoot)
        let linkNode = try XCTUnwrap(node(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertNil(node(at: outsideFile.path, in: result.root))
        XCTAssertEqual(
            result.root.logicalSize,
            result.root.ownLogicalSize + linkNode.ownLogicalSize
        )
        XCTAssertLessThan(result.root.logicalSize, 1_048_576)
    }

    func testSparseFileKeepsLogicalAndAllocatedSizesDistinct() async throws {
        let temporaryDirectory = try TemporaryTestDirectory()
        let sparseFile = temporaryDirectory.url.appendingPathComponent("virtual-disk.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseFile.path, contents: nil))

        let logicalByteCount: UInt64 = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: sparseFile)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let expected = try statValues(for: sparseFile.path)
        let result = await FileTreeScanner().scan(root: temporaryDirectory.url)
        let sparseNode = try XCTUnwrap(node(at: sparseFile.path, in: result.root))

        XCTAssertEqual(sparseNode.ownLogicalSize, expected.logical)
        XCTAssertEqual(sparseNode.ownAllocatedSize, expected.allocated)
        XCTAssertEqual(sparseNode.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertLessThanOrEqual(sparseNode.ownAllocatedSize, sparseNode.ownLogicalSize)

        if sparseNode.ownAllocatedSize >= sparseNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse file.")
        }
    }

    func testPermissionDeniedDirectoryIsReported() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }

        let temporaryDirectory = try TemporaryTestDirectory()
        let inaccessibleDirectory = temporaryDirectory.url.appendingPathComponent("inaccessible", isDirectory: true)
        try FileManager.default.createDirectory(at: inaccessibleDirectory, withIntermediateDirectories: false)
        try Data(repeating: 0x66, count: 128).write(
            to: inaccessibleDirectory.appendingPathComponent("unreadable.dat")
        )

        XCTAssertEqual(chmod(inaccessibleDirectory.path, 0), 0)
        defer { _ = chmod(inaccessibleDirectory.path, mode_t(S_IRWXU)) }

        let result = await FileTreeScanner().scan(root: temporaryDirectory.url)
        let inaccessibleNode = try XCTUnwrap(node(at: inaccessibleDirectory.path, in: result.root))

        XCTAssertEqual(inaccessibleNode.accessibility, .inaccessible)
        XCTAssertTrue(inaccessibleNode.children.isEmpty)
        XCTAssertTrue(inaccessibleNode.scanIssues.contains { $0.kind == .permissionDenied })
        XCTAssertTrue(result.issues.contains {
            $0.path == inaccessibleDirectory.path && $0.kind == .permissionDenied
        })
    }

    func testMissingRootProducesAnErrorNodeInsteadOfThrowing() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-missing-\(UUID().uuidString)", isDirectory: true)

        let result = await FileTreeScanner().scan(root: missingRoot)

        XCTAssertEqual(result.root.absolutePath, missingRoot.standardizedFileURL.path)
        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertFalse(result.root.isCountedInParentTotals)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
    }

    func testCancellationReturnsAPartialMarkedResult() async throws {
        let temporaryDirectory = try TemporaryTestDirectory()
        for index in 0..<300 {
            let directory = temporaryDirectory.url.appendingPathComponent("directory-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(repeating: UInt8(index % 255), count: 64).write(
                to: directory.appendingPathComponent("payload.dat")
            )
        }

        let scanner = FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        let scanTask = Task { await scanner.scan(root: temporaryDirectory.url) }
        scanTask.cancel()
        let result = await scanTask.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
        XCTAssertNotEqual(result.root.accessibility, .accessible)
    }

    func testHardLinksRemainVisibleWithoutDoubleCountingTheirBytes() async throws {
        let temporaryDirectory = try TemporaryTestDirectory()
        let original = temporaryDirectory.url.appendingPathComponent("original.dat")
        let hardLink = temporaryDirectory.url.appendingPathComponent("hard-link.dat")
        try Data(repeating: 0x77, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = await FileTreeScanner().scan(root: temporaryDirectory.url)
        let originalNode = try XCTUnwrap(node(at: original.path, in: result.root))
        let hardLinkNode = try XCTUnwrap(node(at: hardLink.path, in: result.root))
        let linkedNodes = [originalNode, hardLinkNode]

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(originalNode.ownLogicalSize, hardLinkNode.ownLogicalSize)
        XCTAssertEqual(originalNode.ownAllocatedSize, hardLinkNode.ownAllocatedSize)
        XCTAssertEqual(
            result.root.logicalSize,
            result.root.ownLogicalSize + originalNode.ownLogicalSize
        )
        XCTAssertEqual(
            result.root.allocatedSize,
            result.root.ownAllocatedSize + originalNode.ownAllocatedSize
        )
    }
}

private final class TemporaryTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-FileTreeScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func node(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func flattened(_ root: StorageNode) -> [StorageNode] {
    var result: [StorageNode] = []
    var pending = [root]
    while let node = pending.popLast() {
        result.append(node)
        pending.append(contentsOf: node.children)
    }
    return result
}

private func statValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}
