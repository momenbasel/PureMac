import Darwin
import XCTest
@testable import PureMac

final class DataVolumeHiddenStorageAnalyzerTests: XCTestCase {
    func testDiscoversHiddenDotDirectory() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = try makeHiddenDirectory(named: ".hidden", fileSize: 1_024, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        let node = try XCTUnwrap(hiddenNode(at: hidden.path, in: result.root))
        XCTAssertTrue(node.isHidden)
        XCTAssertEqual(node.itemType, .directory)
    }

    func testDiscoversHiddenDotFile() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hiddenFile = temporaryDirectory.url.appendingPathComponent(".hidden-file")
        try Data(repeating: 0x11, count: 2_048).write(to: hiddenFile)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        let node = try XCTUnwrap(hiddenNode(at: hiddenFile.path, in: result.root))
        XCTAssertTrue(node.isHidden)
        XCTAssertEqual(node.itemType, .regularFile)
    }

    func testDiscoversFilesystemHiddenFlagWithoutDotPrefix() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let flagged = temporaryDirectory.url.appendingPathComponent("flagged-hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: flagged, withIntermediateDirectories: false)
        try Data([0x12]).write(to: flagged.appendingPathComponent("payload"))

        guard chflags(flagged.path, UInt32(UF_HIDDEN)) == 0 else {
            throw XCTSkip("The test filesystem does not allow setting UF_HIDDEN.")
        }
        defer { _ = chflags(flagged.path, 0) }

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(hiddenNode(at: flagged.path, in: result.root)?.isHidden, true)
    }

    func testVisibleTopLevelDirectoryIsNotRecursivelyScanned() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let visible = temporaryDirectory.url.appendingPathComponent("Users", isDirectory: true)
        let nested = visible.appendingPathComponent("person/large.dat")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x13, count: 65_536).write(to: nested)
        _ = try makeHiddenDirectory(named: ".selected", fileSize: 1, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertNil(hiddenNode(at: visible.path, in: result.root))
        XCTAssertNil(hiddenNode(at: nested.path, in: result.root))
    }

    func testVisibleRootsDoNotContributeToHiddenStorageTotals() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hiddenFile = temporaryDirectory.url.appendingPathComponent(".selected")
        let visibleFile = temporaryDirectory.url.appendingPathComponent("visible-large.dat")
        try Data(repeating: 0x14, count: 4_096).write(to: hiddenFile)
        try Data(repeating: 0x15, count: 262_144).write(to: visibleFile)
        let expected = try hiddenStatValues(for: hiddenFile.path)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.logicalSize, expected.logical)
        XCTAssertEqual(result.root.allocatedSize, expected.allocated)
        XCTAssertFalse(result.root.isCountedInParentTotals)
    }

    func testDiscoversMultipleHiddenRoots() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let first = try makeHiddenDirectory(named: ".first", fileSize: 1_024, in: temporaryDirectory.url)
        let second = try makeHiddenDirectory(named: ".second", fileSize: 2_048, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(Set(result.root.children.map(\.absolutePath)), Set([first.path, second.path]))
    }

    func testFindingsAreSortedByAllocatedThenLogicalSizeAndPath() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        _ = try makeHiddenDirectory(named: ".small", fileSize: 1, in: temporaryDirectory.url)
        _ = try makeHiddenDirectory(named: ".large", fileSize: 131_072, in: temporaryDirectory.url)
        _ = try makeHiddenDirectory(named: ".medium", fileSize: 32_768, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.children, result.root.children.sorted(by: hiddenStorageOrdering))
        XCTAssertEqual(result.root.children.first?.name, ".large")
    }

    func testAdobeTempIsDiscoveredNaturally() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let adobe = try makeHiddenDirectory(named: ".adobeTemp", fileSize: 4_096, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertNotNil(hiddenNode(at: adobe.path, in: result.root))
    }

    func testAdobeTempHasInformationalProductAttributionWithoutCleanupClassification() async throws {
        let (_, node) = try await analyzeSingleHiddenRoot(named: ".adobeTemp")

        XCTAssertEqual(
            node.metadata.storageCategoryIdentifier,
            DataVolumeHiddenStorageCategory.adobeTemporaryStorage.rawValue
        )
        XCTAssertEqual(hiddenManagementKind(of: node), .productAttributed)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
        XCTAssertTrue(node.metadata.explanation?.contains("no cleanup") == true)
    }

    func testFSEventStoreHasSystemManagedMetadata() async throws {
        let (_, node) = try await analyzeSingleHiddenRoot(named: ".fseventsd")

        XCTAssertEqual(
            node.metadata.storageCategoryIdentifier,
            DataVolumeHiddenStorageCategory.filesystemEvents.rawValue
        )
        XCTAssertEqual(hiddenManagementKind(of: node), .systemManaged)
        XCTAssertTrue(node.metadata.explanation?.contains("macOS") == true)
    }

    func testSpotlightAndDocumentRevisionStoresHaveSystemManagedMetadata() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let spotlight = try makeHiddenDirectory(named: ".Spotlight-V100", fileSize: 1_024, in: temporaryDirectory.url)
        let revisions = try makeHiddenDirectory(named: ".DocumentRevisions-V100", fileSize: 1_024, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let spotlightNode = try XCTUnwrap(hiddenNode(at: spotlight.path, in: result.root))
        let revisionsNode = try XCTUnwrap(hiddenNode(at: revisions.path, in: result.root))

        XCTAssertEqual(
            spotlightNode.metadata.storageCategoryIdentifier,
            DataVolumeHiddenStorageCategory.spotlightIndex.rawValue
        )
        XCTAssertEqual(
            revisionsNode.metadata.storageCategoryIdentifier,
            DataVolumeHiddenStorageCategory.documentRevisions.rawValue
        )
        XCTAssertEqual(hiddenManagementKind(of: spotlightNode), .systemManaged)
        XCTAssertEqual(hiddenManagementKind(of: revisionsNode), .systemManaged)
    }

    func testUnknownHiddenEntryRemainsVisibleAndUnclassified() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let unknown = try makeHiddenDirectory(named: ".future-product-state", fileSize: 2_048, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(hiddenNode(at: unknown.path, in: result.root))

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, DataVolumeHiddenStorageCategory.unknown.rawValue)
        XCTAssertEqual(hiddenManagementKind(of: node), .unknown)
        XCTAssertGreaterThan(node.allocatedSize, 0)
    }

    func testPreservesCompleteHiddenRootHierarchy() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = temporaryDirectory.url.appendingPathComponent(".hierarchy", isDirectory: true)
        let leaf = hidden.appendingPathComponent("one/two/leaf.dat")
        try FileManager.default.createDirectory(
            at: leaf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x16, count: 1_024).write(to: leaf)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertNotNil(hiddenNode(at: leaf.path, in: result.root))
        XCTAssertEqual(hiddenNode(at: hidden.path, in: result.root)?.children.first?.name, "one")
    }

    func testIncludesHiddenDescendantsWithinSelectedRoot() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = temporaryDirectory.url.appendingPathComponent(".root", isDirectory: true)
        let hiddenChild = hidden.appendingPathComponent(".internal", isDirectory: true)
        let hiddenFile = hiddenChild.appendingPathComponent(".payload")
        try FileManager.default.createDirectory(at: hiddenChild, withIntermediateDirectories: true)
        try Data([0x17]).write(to: hiddenFile)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(hiddenNode(at: hiddenChild.path, in: result.root)?.isHidden, true)
        XCTAssertEqual(hiddenNode(at: hiddenFile.path, in: result.root)?.isHidden, true)
    }

    func testLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let file = temporaryDirectory.url.appendingPathComponent(".sized-file")
        try Data(repeating: 0x18, count: 33_333).write(to: file)
        let expected = try hiddenStatValues(for: file.path)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(hiddenNode(at: file.path, in: result.root))

        XCTAssertEqual(node.ownLogicalSize, expected.logical)
        XCTAssertEqual(node.ownAllocatedSize, expected.allocated)
    }

    func testSparseVirtualDiskPreservesLogicalAndAllocatedSizes() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hiddenRoot = temporaryDirectory.url.appendingPathComponent(".vm-state", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: false)
        let disk = hiddenRoot.appendingPathComponent("machine.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024)
        try handle.close()

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let diskNode = try XCTUnwrap(hiddenNode(at: disk.path, in: result.root))

        XCTAssertEqual(diskNode.ownLogicalSize, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(diskNode.ownAllocatedSize, diskNode.ownLogicalSize)
        XCTAssertEqual(
            diskNode.metadata.attributes[DataVolumeHiddenStorageAnalyzer.MetadataKey.virtualDiskFormat],
            "raw"
        )
        XCTAssertEqual(
            hiddenNode(at: hiddenRoot.path, in: result.root)?.metadata.attributes[
                DataVolumeHiddenStorageAnalyzer.MetadataKey.virtualDiskImageCount
            ],
            "1"
        )
    }

    func testSymbolicLinkIsVisibleWithoutFollowingTarget() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let outside = temporaryDirectory.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideFile = outside.appendingPathComponent("large.dat")
        try Data(repeating: 0x19, count: 262_144).write(to: outsideFile)
        let link = temporaryDirectory.url.appendingPathComponent(".hidden-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let linkNode = try XCTUnwrap(hiddenNode(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertNil(hiddenNode(at: outsideFile.path, in: result.root))
    }

    func testHardLinksInsideOneHiddenRootAreDeduplicated() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = temporaryDirectory.url.appendingPathComponent(".links", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        let original = hidden.appendingPathComponent("original")
        let link = hidden.appendingPathComponent("link")
        try Data(repeating: 0x20, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let linkedNodes = [
            try XCTUnwrap(hiddenNode(at: original.path, in: result.root)),
            try XCTUnwrap(hiddenNode(at: link.path, in: result.root))
        ]

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
    }

    func testHardLinksAcrossSelectedHiddenRootsShareDeduplicationContext() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let first = try makeHiddenDirectory(named: ".first", fileSize: 0, in: temporaryDirectory.url)
        let second = try makeHiddenDirectory(named: ".second", fileSize: 0, in: temporaryDirectory.url)
        let original = first.appendingPathComponent("shared.dat")
        let link = second.appendingPathComponent("shared.dat")
        try Data(repeating: 0x21, count: 16_384).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let linkedNodes = [
            try XCTUnwrap(hiddenNode(at: original.path, in: result.root)),
            try XCTUnwrap(hiddenNode(at: link.path, in: result.root))
        ]

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
        let countedBytes = linkedNodes.filter(\.isCountedInParentTotals).reduce(Int64(0)) {
            $0 + $1.ownAllocatedSize
        }
        XCTAssertEqual(countedBytes, linkedNodes[0].ownAllocatedSize)
    }

    func testFilesystemBoundaryRemainsVisibleAndExcluded() throws {
        let boundary = syntheticHiddenNode(
            name: ".mounted",
            path: "/System/Volumes/Data/.mounted",
            itemType: .volumeBoundary,
            accessibility: .skippedDifferentVolume,
            isHidden: true,
            isCounted: false
        )
        let root = syntheticHiddenNode(
            name: "Data",
            path: "/System/Volumes/Data",
            itemType: .directory,
            children: [boundary],
            isCounted: false
        )

        let result = DataVolumeHiddenStorageAnalyzer.enrich(
            syntheticHiddenResult(root: root),
            largeAllocatedSizeThreshold: 1
        )
        let node = try XCTUnwrap(hiddenNode(at: boundary.absolutePath, in: result.root))

        XCTAssertEqual(node.itemType, .volumeBoundary)
        XCTAssertEqual(hiddenSizeKnowledge(of: node), .excludedDifferentVolume)
        XCTAssertEqual(result.root.allocatedSize, 0)
    }

    func testPermissionDeniedHiddenRootPreservesIssueAndPOSIXCode() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 directories.") }
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let protected = try makeHiddenDirectory(named: ".protected", fileSize: 128, in: temporaryDirectory.url)
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(hiddenNode(at: protected.path, in: result.root))

        XCTAssertEqual(node.accessibility, .inaccessible)
        XCTAssertTrue(node.scanIssues.contains {
            $0.kind == .permissionDenied && ($0.posixErrorCode == EACCES || $0.posixErrorCode == EPERM)
        })
    }

    func testUnknownIncompleteSizeIsDistinctFromAccessibleZero() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 directories.") }
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let empty = try makeHiddenDirectory(named: ".empty", fileSize: 0, in: temporaryDirectory.url)
        let inaccessible = try makeHiddenDirectory(named: ".unknown", fileSize: 4_096, in: temporaryDirectory.url)
        XCTAssertEqual(chmod(inaccessible.path, 0), 0)
        defer { _ = chmod(inaccessible.path, mode_t(S_IRWXU)) }

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let emptyNode = try XCTUnwrap(hiddenNode(at: empty.path, in: result.root))
        let inaccessibleNode = try XCTUnwrap(hiddenNode(at: inaccessible.path, in: result.root))

        XCTAssertEqual(hiddenSizeKnowledge(of: emptyNode), .complete)
        XCTAssertEqual(hiddenSizeKnowledge(of: inaccessibleNode), .incompleteDueToInaccessibility)
    }

    func testCancellationReturnsVisiblePartialMarkedAnalysis() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = temporaryDirectory.url.appendingPathComponent(".large-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        for index in 0..<300 {
            let directory = hidden.appendingPathComponent("directory-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([UInt8(index % 255)]).write(to: directory.appendingPathComponent("payload"))
        }

        let analyzer = makeAnalyzer(
            root: temporaryDirectory.url,
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let task = Task { await analyzer.analyze() }
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
        XCTAssertEqual(hiddenSizeKnowledge(of: result.root), .incompleteDueToCancellation)
    }

    func testEmptyDataVolumeRootReturnsAccessibleZeroAnalysis() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(result.root.logicalSize, 0)
        XCTAssertEqual(result.root.allocatedSize, 0)
        XCTAssertEqual(result.root.accessibility, .accessible)
    }

    func testRootContainingOnlyVisibleEntriesReturnsNoFindings() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        _ = try makeVisibleDirectory(named: "Library", fileSize: 8_192, in: temporaryDirectory.url)
        _ = try makeVisibleDirectory(named: "Users", fileSize: 8_192, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(result.root.allocatedSize, 0)
    }

    func testMissingRootReturnsTypedUnavailableAnalysis() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-MissingDataVolume-\(UUID().uuidString)", isDirectory: true)

        let result = await makeAnalyzer(root: missing).analyze()

        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
    }

    func testNonDirectoryRootReturnsTypedNotDirectoryIssue() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let file = temporaryDirectory.url.appendingPathComponent("data-volume-file")
        try Data([0x22]).write(to: file)

        let result = await makeAnalyzer(root: file).analyze()

        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.issues.contains {
            $0.path == file.path && $0.kind == .notDirectory && $0.posixErrorCode == ENOTDIR
        })
    }

    func testAccountingReconcilesToSelectedHiddenTreeOnly() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        _ = try makeHiddenDirectory(named: ".one", fileSize: 8_192, in: temporaryDirectory.url)
        _ = try makeHiddenDirectory(named: ".two", fileSize: 16_384, in: temporaryDirectory.url)
        _ = try makeVisibleDirectory(named: "private", fileSize: 65_536, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
        let countedNodes = flattenedHiddenTree(result.root).filter(\.isCountedInParentTotals)

        XCTAssertEqual(
            result.root.logicalSize,
            countedNodes.reduce(Int64(0)) { $0 + $1.ownLogicalSize }
        )
        XCTAssertEqual(
            result.root.allocatedSize,
            countedNodes.reduce(Int64(0)) { $0 + $1.ownAllocatedSize }
        )
    }

    func testAnalysisDoesNotMutateHiddenStorage() async throws {
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let hidden = try makeHiddenDirectory(named: ".important", fileSize: 0, in: temporaryDirectory.url)
        let file = hidden.appendingPathComponent("state.db")
        let original = Data(repeating: 0x23, count: 4_096)
        try original.write(to: file)
        let originalMode = try hiddenStatMode(for: file.path)

        _ = await makeAnalyzer(root: temporaryDirectory.url, largeAllocatedSizeThreshold: 1).analyze()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try hiddenStatMode(for: file.path), originalMode)
    }

    func testLargeVisibleSiblingTreeIsNeverTraversed() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 directories.") }
        let temporaryDirectory = try DataVolumeHiddenTestDirectory()
        let visible = temporaryDirectory.url.appendingPathComponent("Users", isDirectory: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: false)
        for index in 0..<200 {
            let directory = visible.appendingPathComponent("user-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([0x24]).write(to: directory.appendingPathComponent("payload"))
        }
        XCTAssertEqual(chmod(visible.path, 0), 0)
        defer { _ = chmod(visible.path, mode_t(S_IRWXU)) }
        let selected = try makeHiddenDirectory(named: ".selected", fileSize: 1_024, in: temporaryDirectory.url)

        let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.children.map(\.absolutePath), [selected.path])
        XCTAssertFalse(result.issues.contains { $0.path.hasPrefix(visible.path) })
    }
}

private final class DataVolumeHiddenTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-DataVolumeHiddenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner(),
    largeAllocatedSizeThreshold: Int64 = DataVolumeHiddenStorageAnalyzer.defaultLargeAllocatedSizeThreshold
) -> DataVolumeHiddenStorageAnalyzer {
    DataVolumeHiddenStorageAnalyzer(
        dataVolumeURL: root,
        scanner: scanner,
        largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
    )
}

@discardableResult
private func makeHiddenDirectory(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    if fileSize > 0 {
        try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
            to: directory.appendingPathComponent("payload.dat")
        )
    }
    return directory
}

@discardableResult
private func makeVisibleDirectory(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    if fileSize > 0 {
        try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
            to: directory.appendingPathComponent("payload.dat")
        )
    }
    return directory
}

private func analyzeSingleHiddenRoot(
    named name: String
) async throws -> (DataVolumeHiddenTestDirectory, StorageNode) {
    let temporaryDirectory = try DataVolumeHiddenTestDirectory()
    let root = try makeHiddenDirectory(named: name, fileSize: 1_024, in: temporaryDirectory.url)
    let result = await makeAnalyzer(root: temporaryDirectory.url).analyze()
    return (temporaryDirectory, try XCTUnwrap(hiddenNode(at: root.path, in: result.root)))
}

private func hiddenNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let node = pending.popLast() {
        if node.absolutePath == path { return node }
        pending.append(contentsOf: node.children)
    }
    return nil
}

private func flattenedHiddenTree(_ root: StorageNode) -> [StorageNode] {
    var nodes: [StorageNode] = []
    var pending = [root]
    while let node = pending.popLast() {
        nodes.append(node)
        pending.append(contentsOf: node.children)
    }
    return nodes
}

private func hiddenStorageOrdering(_ left: StorageNode, _ right: StorageNode) -> Bool {
    if left.allocatedSize != right.allocatedSize { return left.allocatedSize > right.allocatedSize }
    if left.logicalSize != right.logicalSize { return left.logicalSize > right.logicalSize }
    return left.absolutePath < right.absolutePath
}

private func hiddenManagementKind(of node: StorageNode) -> DataVolumeHiddenManagementKind? {
    node.metadata.attributes[DataVolumeHiddenStorageAnalyzer.MetadataKey.managementKind]
        .flatMap(DataVolumeHiddenManagementKind.init(rawValue:))
}

private func hiddenSizeKnowledge(of node: StorageNode) -> DataVolumeHiddenSizeKnowledge? {
    node.metadata.attributes[DataVolumeHiddenStorageAnalyzer.MetadataKey.sizeKnowledge]
        .flatMap(DataVolumeHiddenSizeKnowledge.init(rawValue:))
}

private func hiddenStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (Int64(metadata.st_size), Int64(metadata.st_blocks) * 512)
}

private func hiddenStatMode(for path: String) throws -> mode_t {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return metadata.st_mode
}

private func syntheticHiddenResult(root: StorageNode) -> StorageAnalysisResult {
    StorageAnalysisResult(
        root: root,
        startedAt: Date(),
        completedAt: Date(),
        rootDeviceIdentifier: 1,
        wasCancelled: false,
        issues: root.scanIssues
    )
}

private func syntheticHiddenNode(
    name: String,
    path: String,
    itemType: StorageItemType,
    children: [StorageNode] = [],
    accessibility: StorageAccessibility = .accessible,
    isHidden: Bool = false,
    isCounted: Bool = true
) -> StorageNode {
    StorageNode(
        name: name,
        absolutePath: path,
        logicalSize: children.reduce(0) { $0 + $1.logicalSize },
        allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
        ownLogicalSize: 0,
        ownAllocatedSize: 0,
        itemType: itemType,
        children: children,
        accessibility: accessibility,
        scanIssues: [],
        isHidden: isHidden,
        isSymbolicLink: false,
        isCountedInParentTotals: isCounted,
        metadata: StorageAnalysisMetadata()
    )
}
