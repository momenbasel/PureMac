import Darwin
import XCTest
@testable import PureMac

final class ContainersAnalyzerTests: XCTestCase {
    func testAnalyzesMultipleContainersAndSortsLargestAllocatedSizeFirst() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        try makeContainer(named: "com.example.small", fileSize: 4_096, in: temporaryDirectory.url)
        try makeContainer(named: "com.example.medium", fileSize: 131_072, in: temporaryDirectory.url)
        try makeContainer(named: "com.example.large", fileSize: 2_097_152, in: temporaryDirectory.url)

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containers = result.root.children

        XCTAssertEqual(
            containers.map(\.name),
            ["com.example.large", "com.example.medium", "com.example.small"]
        )
        XCTAssertTrue(zip(containers, containers.dropFirst()).allSatisfy {
            $0.allocatedSize >= $1.allocatedSize
        })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "containers")
        XCTAssertEqual(
            result.root.metadata.attributes[ContainersAnalyzer.MetadataKey.directChildCount],
            "3"
        )
    }

    func testRecognizesBundleIdentifierCandidatesAndOnlyAcceptsVerifiedAttribution() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        let verifiedContainer = try makeContainer(
            named: "com.example.verified",
            fileSize: 16_384,
            in: temporaryDirectory.url
        )
        let unresolvedContainer = try makeContainer(
            named: "com.example.unresolved",
            fileSize: 8_192,
            in: temporaryDirectory.url
        )
        let nonBundleContainer = try makeContainer(
            named: "Not A Bundle Identifier",
            fileSize: 4_096,
            in: temporaryDirectory.url
        )

        let analyzer = ContainersAnalyzer(
            containersURL: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1,
            attributionProvider: { bundleIdentifier in
                switch bundleIdentifier {
                case "com.example.verified":
                    return .init(
                        bundleIdentifier: "com.example.verified",
                        displayName: "Verified App"
                    )
                case "com.example.unresolved":
                    return .init(
                        bundleIdentifier: "com.different.application",
                        displayName: "Wrong App"
                    )
                default:
                    return nil
                }
            }
        )
        let result = await analyzer.analyze()
        let verifiedNode = try XCTUnwrap(node(at: verifiedContainer.path, in: result.root))
        let unresolvedNode = try XCTUnwrap(node(at: unresolvedContainer.path, in: result.root))
        let nonBundleNode = try XCTUnwrap(node(at: nonBundleContainer.path, in: result.root))

        XCTAssertEqual(verifiedNode.metadata.bundleIdentifier, "com.example.verified")
        XCTAssertEqual(verifiedNode.metadata.owningApplicationIdentifier, "com.example.verified")
        XCTAssertEqual(verifiedNode.metadata.owningApplicationName, "Verified App")
        XCTAssertEqual(verifiedNode.metadata.confidence, 1)
        XCTAssertEqual(verifiedNode.metadata.isUnusuallyLarge, true)
        XCTAssertNil(verifiedNode.metadata.safetyClassificationIdentifier)
        XCTAssertEqual(
            verifiedNode.metadata.attributes[ContainersAnalyzer.MetadataKey.bundleIdentifierSource],
            "directory-name"
        )

        XCTAssertEqual(unresolvedNode.metadata.bundleIdentifier, "com.example.unresolved")
        XCTAssertNil(unresolvedNode.metadata.owningApplicationIdentifier)
        XCTAssertNil(unresolvedNode.metadata.owningApplicationName)
        XCTAssertNil(unresolvedNode.metadata.confidence)

        XCTAssertNil(nonBundleNode.metadata.bundleIdentifier)
        XCTAssertNil(nonBundleNode.metadata.owningApplicationIdentifier)
        XCTAssertNil(nonBundleNode.metadata.owningApplicationName)
    }

    func testIncludesHiddenContentAndPreservesContainerHierarchy() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        let container = temporaryDirectory.url.appendingPathComponent("com.example.hidden", isDirectory: true)
        let dataDirectory = container.appendingPathComponent("Data", isDirectory: true)
        let libraryDirectory = dataDirectory.appendingPathComponent("Library", isDirectory: true)
        let hiddenDirectory = libraryDirectory.appendingPathComponent(".internal-state", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent(".payload")
        try Data(repeating: 0x21, count: 1_024).write(to: hiddenFile)

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(node(at: container.path, in: result.root))
        let dataNode = try XCTUnwrap(node(at: dataDirectory.path, in: result.root))
        let libraryNode = try XCTUnwrap(node(at: libraryDirectory.path, in: result.root))
        let hiddenDirectoryNode = try XCTUnwrap(node(at: hiddenDirectory.path, in: result.root))
        let hiddenFileNode = try XCTUnwrap(node(at: hiddenFile.path, in: result.root))

        XCTAssertEqual(containerNode.children.map(\.name), ["Data"])
        XCTAssertEqual(dataNode.children.map(\.name), ["Library"])
        XCTAssertEqual(libraryNode.children.map(\.name), [".internal-state"])
        XCTAssertTrue(hiddenDirectoryNode.isHidden)
        XCTAssertTrue(hiddenFileNode.isHidden)
        XCTAssertEqual(
            containerNode.metadata.attributes[ContainersAnalyzer.MetadataKey.directChildCount],
            "1"
        )
    }

    func testPreservesSparseVirtualDiskLogicalAndAllocatedSizes() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        let container = temporaryDirectory.url.appendingPathComponent("com.example.virtualizer", isDirectory: true)
        let dataDirectory = container.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let virtualDisk = dataDirectory.appendingPathComponent("machine.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: virtualDisk.path, contents: nil))

        let logicalByteCount: UInt64 = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: virtualDisk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let expected = try containersStatValues(for: virtualDisk.path)
        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(node(at: container.path, in: result.root))
        let diskNode = try XCTUnwrap(node(at: virtualDisk.path, in: result.root))

        XCTAssertEqual(diskNode.ownLogicalSize, expected.logical)
        XCTAssertEqual(diskNode.ownAllocatedSize, expected.allocated)
        XCTAssertEqual(diskNode.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertEqual(
            containerNode.metadata.attributes[ContainersAnalyzer.MetadataKey.virtualDiskImageCount],
            "1"
        )

        if diskNode.ownAllocatedSize >= diskNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse virtual disk.")
        }
    }

    func testPermissionDeniedContainerRemainsVisibleWithIssue() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }

        let temporaryDirectory = try ContainersTestDirectory()
        let inaccessibleContainer = try makeContainer(
            named: "com.example.inaccessible",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        XCTAssertEqual(chmod(inaccessibleContainer.path, 0), 0)
        defer { _ = chmod(inaccessibleContainer.path, mode_t(S_IRWXU)) }

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let inaccessibleNode = try XCTUnwrap(node(at: inaccessibleContainer.path, in: result.root))

        XCTAssertEqual(inaccessibleNode.accessibility, .inaccessible)
        XCTAssertTrue(inaccessibleNode.children.isEmpty)
        XCTAssertTrue(inaccessibleNode.scanIssues.contains { $0.kind == .permissionDenied })
        XCTAssertTrue(result.issues.contains {
            $0.path == inaccessibleContainer.path && $0.kind == .permissionDenied
        })
    }

    func testSymbolicLinkIsNotFollowedOrAttributedAsContainer() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        let outsideDirectory = try ContainersTestDirectory()
        let outsideFile = outsideDirectory.url.appendingPathComponent("outside.dat")
        try Data(repeating: 0x31, count: 1_048_576).write(to: outsideFile)
        let link = temporaryDirectory.url.appendingPathComponent("com.example.external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory.url)

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let linkNode = try XCTUnwrap(node(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertNil(linkNode.metadata.bundleIdentifier)
        XCTAssertNil(linkNode.metadata.owningApplicationIdentifier)
        XCTAssertNil(node(at: outsideFile.path, in: result.root))
        XCTAssertLessThan(result.root.logicalSize, 1_048_576)
    }

    func testCancellationReturnsPartialMarkedAnalysis() async throws {
        let temporaryDirectory = try ContainersTestDirectory()
        for index in 0..<300 {
            try makeContainer(
                named: "com.example.application-\(index)",
                fileSize: 64,
                in: temporaryDirectory.url
            )
        }

        let analyzer = makeContainersAnalyzer(
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
        let temporaryDirectory = try ContainersTestDirectory()
        let container = temporaryDirectory.url.appendingPathComponent("com.example.linked", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let original = container.appendingPathComponent("original.dat")
        let hardLink = container.appendingPathComponent("linked.dat")
        try Data(repeating: 0x41, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(node(at: container.path, in: result.root))
        let originalNode = try XCTUnwrap(node(at: original.path, in: result.root))
        let hardLinkNode = try XCTUnwrap(node(at: hardLink.path, in: result.root))
        let linkedNodes = [originalNode, hardLinkNode]

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(
            containerNode.logicalSize,
            containerNode.ownLogicalSize + originalNode.ownLogicalSize
        )
        XCTAssertEqual(
            containerNode.allocatedSize,
            containerNode.ownAllocatedSize + originalNode.ownAllocatedSize
        )
        XCTAssertEqual(result.root.logicalSize, result.root.ownLogicalSize + containerNode.logicalSize)
        XCTAssertEqual(result.root.allocatedSize, result.root.ownAllocatedSize + containerNode.allocatedSize)
    }

    func testEmptyContainersDirectoryReturnsNoEntries() async throws {
        let temporaryDirectory = try ContainersTestDirectory()

        let result = await makeContainersAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(result.root.accessibility, .accessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(
            result.root.metadata.attributes[ContainersAnalyzer.MetadataKey.directChildCount],
            "0"
        )
    }

    func testMissingContainersDirectoryReturnsUnavailableResult() async {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Missing-Containers-\(UUID().uuidString)", isDirectory: true)

        let result = await makeContainersAnalyzer(root: missingDirectory).analyze()

        XCTAssertEqual(result.root.absolutePath, missingDirectory.standardizedFileURL.path)
        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "containers")
    }
}

private final class ContainersTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-ContainersAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeContainersAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner()
) -> ContainersAnalyzer {
    ContainersAnalyzer(
        containersURL: root,
        scanner: scanner,
        attributionProvider: { _ in nil }
    )
}

@discardableResult
private func makeContainer(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let container = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
        to: container.appendingPathComponent("payload.dat")
    )
    return container
}

private func node(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func containersStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}
