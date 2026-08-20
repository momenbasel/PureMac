import Darwin
import XCTest
@testable import PureMac

final class ApplicationSupportAnalyzerTests: XCTestCase {
    func testAnalyzesMultipleFoldersAndSortsLargestAllocatedSizeFirst() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        try makeApplicationFolder(named: "Small", fileSize: 4_096, in: temporaryDirectory.url)
        try makeApplicationFolder(named: "Medium", fileSize: 131_072, in: temporaryDirectory.url)
        try makeApplicationFolder(named: "Large", fileSize: 2_097_152, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let entries = result.root.children

        XCTAssertEqual(entries.map(\.name), ["Large", "Medium", "Small"])
        XCTAssertTrue(zip(entries, entries.dropFirst()).allSatisfy {
            $0.allocatedSize >= $1.allocatedSize
        })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "application-support")
        XCTAssertEqual(
            result.root.metadata.attributes[ApplicationSupportAnalyzer.MetadataKey.directChildCount],
            "3"
        )
    }

    func testIncludesHiddenFoldersAndAddsConservativeAttributionAndLargeMetadata() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        let attributedFolder = try makeApplicationFolder(
            named: "com.example.editor",
            fileSize: 16_384,
            in: temporaryDirectory.url
        )
        let hiddenFolder = try makeApplicationFolder(
            named: ".internal-state",
            fileSize: 1_024,
            in: temporaryDirectory.url
        )

        let analyzer = ApplicationSupportAnalyzer(
            applicationSupportURL: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1,
            attributionProvider: { directoryName in
                guard directoryName == "com.example.editor" else { return nil }
                return .init(
                    bundleIdentifier: "com.example.editor",
                    displayName: "Example Editor"
                )
            }
        )
        let result = await analyzer.analyze()
        let attributedNode = try XCTUnwrap(node(at: attributedFolder.path, in: result.root))
        let hiddenNode = try XCTUnwrap(node(at: hiddenFolder.path, in: result.root))

        XCTAssertTrue(hiddenNode.isHidden)
        XCTAssertEqual(attributedNode.metadata.owningApplicationIdentifier, "com.example.editor")
        XCTAssertEqual(attributedNode.metadata.owningApplicationName, "Example Editor")
        XCTAssertEqual(attributedNode.metadata.confidence, 1)
        XCTAssertEqual(attributedNode.metadata.isUnusuallyLarge, true)
        XCTAssertNil(attributedNode.metadata.safetyClassificationIdentifier)
        XCTAssertEqual(
            attributedNode.metadata.attributes[ApplicationSupportAnalyzer.MetadataKey.directChildCount],
            "1"
        )
        XCTAssertNil(hiddenNode.metadata.owningApplicationIdentifier)
        XCTAssertNil(hiddenNode.metadata.owningApplicationName)
    }

    func testPreservesSparseVirtualDiskLogicalAndAllocatedSizes() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        let appFolder = temporaryDirectory.url.appendingPathComponent("Virtualizer", isDirectory: true)
        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: false)
        let virtualDisk = appFolder.appendingPathComponent("machine.qcow2")
        XCTAssertTrue(FileManager.default.createFile(atPath: virtualDisk.path, contents: nil))

        let logicalByteCount: UInt64 = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: virtualDisk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let expected = try applicationSupportStatValues(for: virtualDisk.path)
        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let appNode = try XCTUnwrap(node(at: appFolder.path, in: result.root))
        let diskNode = try XCTUnwrap(node(at: virtualDisk.path, in: result.root))

        XCTAssertEqual(diskNode.ownLogicalSize, expected.logical)
        XCTAssertEqual(diskNode.ownAllocatedSize, expected.allocated)
        XCTAssertEqual(diskNode.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertEqual(
            appNode.metadata.attributes[ApplicationSupportAnalyzer.MetadataKey.virtualDiskImageCount],
            "1"
        )

        if diskNode.ownAllocatedSize >= diskNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse virtual disk.")
        }
    }

    func testUnreadableFolderRemainsVisibleWithPermissionIssue() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }

        let temporaryDirectory = try ApplicationSupportTestDirectory()
        let unreadableFolder = try makeApplicationFolder(
            named: "UnreadableApp",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        XCTAssertEqual(chmod(unreadableFolder.path, 0), 0)
        defer { _ = chmod(unreadableFolder.path, mode_t(S_IRWXU)) }

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let unreadableNode = try XCTUnwrap(node(at: unreadableFolder.path, in: result.root))

        XCTAssertEqual(unreadableNode.accessibility, .inaccessible)
        XCTAssertTrue(unreadableNode.children.isEmpty)
        XCTAssertTrue(unreadableNode.scanIssues.contains { $0.kind == .permissionDenied })
        XCTAssertTrue(result.issues.contains {
            $0.path == unreadableFolder.path && $0.kind == .permissionDenied
        })
    }

    func testSymbolicLinkIsNotFollowed() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        let outsideDirectory = try ApplicationSupportTestDirectory()
        let outsideFile = outsideDirectory.url.appendingPathComponent("outside.dat")
        try Data(repeating: 0x41, count: 1_048_576).write(to: outsideFile)
        let link = temporaryDirectory.url.appendingPathComponent("ExternalData")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let linkNode = try XCTUnwrap(node(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertNil(node(at: outsideFile.path, in: result.root))
        XCTAssertLessThan(result.root.logicalSize, 1_048_576)
    }

    func testCancellationReturnsPartialMarkedAnalysis() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        for index in 0..<300 {
            try makeApplicationFolder(
                named: "Application-\(index)",
                fileSize: 64,
                in: temporaryDirectory.url
            )
        }

        let analyzer = makeAnalyzer(
            root: temporaryDirectory.url,
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let analysisTask = Task { await analyzer.analyze() }
        analysisTask.cancel()
        let result = await analysisTask.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
        XCTAssertNotEqual(result.root.accessibility, .accessible)
    }

    func testHardLinksAreNotDoubleCounted() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()
        let appFolder = temporaryDirectory.url.appendingPathComponent("LinkedDataApp", isDirectory: true)
        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: false)
        let original = appFolder.appendingPathComponent("original.dat")
        let hardLink = appFolder.appendingPathComponent("linked.dat")
        try Data(repeating: 0x51, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let appNode = try XCTUnwrap(node(at: appFolder.path, in: result.root))
        let originalNode = try XCTUnwrap(node(at: original.path, in: result.root))
        let hardLinkNode = try XCTUnwrap(node(at: hardLink.path, in: result.root))
        let linkedNodes = [originalNode, hardLinkNode]

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(
            appNode.logicalSize,
            appNode.ownLogicalSize + originalNode.ownLogicalSize
        )
        XCTAssertEqual(
            appNode.allocatedSize,
            appNode.ownAllocatedSize + originalNode.ownAllocatedSize
        )
        XCTAssertEqual(result.root.logicalSize, result.root.ownLogicalSize + appNode.logicalSize)
        XCTAssertEqual(result.root.allocatedSize, result.root.ownAllocatedSize + appNode.allocatedSize)
    }

    func testEmptyApplicationSupportDirectoryReturnsNoEntries() async throws {
        let temporaryDirectory = try ApplicationSupportTestDirectory()

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(result.root.accessibility, .accessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(
            result.root.metadata.attributes[ApplicationSupportAnalyzer.MetadataKey.directChildCount],
            "0"
        )
    }

    func testMissingApplicationSupportDirectoryReturnsUnavailableResult() async {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Missing-Application-Support-\(UUID().uuidString)", isDirectory: true)

        let result = await makeAnalyzer(root: missingDirectory).analyze()

        XCTAssertEqual(result.root.absolutePath, missingDirectory.standardizedFileURL.path)
        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "application-support")
    }
}

private final class ApplicationSupportTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-ApplicationSupportAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner()
) -> ApplicationSupportAnalyzer {
    ApplicationSupportAnalyzer(
        applicationSupportURL: root,
        scanner: scanner,
        attributionProvider: { _ in nil }
    )
}

@discardableResult
private func makeApplicationFolder(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
        to: folder.appendingPathComponent("payload.dat")
    )
    return folder
}

private func node(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func applicationSupportStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}
