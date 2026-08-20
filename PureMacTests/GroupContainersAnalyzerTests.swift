import Darwin
import XCTest
@testable import PureMac

final class GroupContainersAnalyzerTests: XCTestCase {
    func testAnalyzesMultipleGroupContainersAndSortsLargestAllocatedSizeFirst() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        try makeGroupContainer(named: "group.com.example.small", fileSize: 4_096, in: temporaryDirectory.url)
        try makeGroupContainer(named: "group.com.example.medium", fileSize: 131_072, in: temporaryDirectory.url)
        try makeGroupContainer(named: "group.com.example.large", fileSize: 2_097_152, in: temporaryDirectory.url)

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let groupContainers = result.root.children

        XCTAssertEqual(
            groupContainers.map(\.name),
            ["group.com.example.large", "group.com.example.medium", "group.com.example.small"]
        )
        XCTAssertTrue(zip(groupContainers, groupContainers.dropFirst()).allSatisfy { left, right in
            if left.allocatedSize != right.allocatedSize {
                return left.allocatedSize > right.allocatedSize
            }
            if left.logicalSize != right.logicalSize {
                return left.logicalSize > right.logicalSize
            }
            return left.absolutePath < right.absolutePath
        })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "group-containers")
        XCTAssertEqual(
            result.root.metadata.attributes[GroupContainersAnalyzer.MetadataKey.directChildCount],
            "3"
        )
    }

    func testPreservesStructurallyValidGroupIdentifiersWithoutTreatingThemAsOwners() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        let groupPrefixed = try makeGroupContainer(
            named: "group.com.example.shared",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        let teamPrefixed = try makeGroupContainer(
            named: "ABCDE12345.com.example.shared",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        let entitlementStyle = try makeGroupContainer(
            named: "com.example.shared-suite",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        let invalid = try makeGroupContainer(
            named: "Not A Group Identifier",
            fileSize: 128,
            in: temporaryDirectory.url
        )

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let groupNode = try XCTUnwrap(groupContainersNode(at: groupPrefixed.path, in: result.root))
        let teamNode = try XCTUnwrap(groupContainersNode(at: teamPrefixed.path, in: result.root))
        let entitlementNode = try XCTUnwrap(groupContainersNode(at: entitlementStyle.path, in: result.root))
        let invalidNode = try XCTUnwrap(groupContainersNode(at: invalid.path, in: result.root))

        XCTAssertEqual(groupNode.metadata.groupContainerIdentifier, groupPrefixed.lastPathComponent)
        XCTAssertEqual(
            groupNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.groupIdentifierSource],
            "group-prefix-directory-name"
        )
        XCTAssertEqual(teamNode.metadata.groupContainerIdentifier, teamPrefixed.lastPathComponent)
        XCTAssertEqual(
            teamNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.groupIdentifierSource],
            "team-id-prefix-directory-name"
        )
        XCTAssertEqual(entitlementNode.metadata.groupContainerIdentifier, entitlementStyle.lastPathComponent)
        XCTAssertEqual(
            entitlementNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.groupIdentifierSource],
            "entitlement-style-directory-name"
        )

        for candidate in [groupNode, teamNode, entitlementNode] {
            XCTAssertNil(candidate.metadata.bundleIdentifier)
            XCTAssertNil(candidate.metadata.owningApplicationIdentifier)
            XCTAssertNil(candidate.metadata.owningApplicationName)
            XCTAssertNil(candidate.metadata.owningApplications)
            XCTAssertNil(candidate.metadata.confidence)
        }
        XCTAssertNil(invalidNode.metadata.groupContainerIdentifier)
    }

    func testRepresentsMultipleVerifiedOwnersWithoutForcingLegacySingleOwner() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        let sharedContainer = try makeGroupContainer(
            named: "group.com.example.product-suite",
            fileSize: 16_384,
            in: temporaryDirectory.url
        )
        let analyzer = GroupContainersAnalyzer(
            groupContainersURL: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1,
            attributionProvider: { identifier in
                guard identifier == "group.com.example.product-suite" else { return [] }
                return [
                    .init(bundleIdentifier: "com.example.helper", displayName: "Example Helper"),
                    .init(bundleIdentifier: "com.example.main", displayName: "Example App"),
                    .init(bundleIdentifier: "com.example.main", displayName: "Duplicate"),
                ]
            }
        )

        let result = await analyzer.analyze()
        let sharedNode = try XCTUnwrap(groupContainersNode(at: sharedContainer.path, in: result.root))

        XCTAssertEqual(
            sharedNode.metadata.owningApplications,
            [
                .init(bundleIdentifier: "com.example.helper", displayName: "Example Helper"),
                .init(bundleIdentifier: "com.example.main", displayName: "Example App"),
            ]
        )
        XCTAssertNil(sharedNode.metadata.bundleIdentifier)
        XCTAssertNil(sharedNode.metadata.owningApplicationIdentifier)
        XCTAssertNil(sharedNode.metadata.owningApplicationName)
        XCTAssertEqual(sharedNode.metadata.confidence, 1)
        XCTAssertEqual(sharedNode.metadata.isUnusuallyLarge, true)
        XCTAssertNil(sharedNode.metadata.safetyClassificationIdentifier)
        XCTAssertEqual(
            sharedNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.ownerCount],
            "2"
        )
    }

    func testIncludesHiddenContentAndPreservesCompleteHierarchy() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        let groupContainer = temporaryDirectory.url
            .appendingPathComponent("group.com.example.hidden", isDirectory: true)
        let libraryDirectory = groupContainer
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let hiddenDirectory = libraryDirectory.appendingPathComponent(".internal-state", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent(".payload")
        try Data(repeating: 0x21, count: 1_024).write(to: hiddenFile)

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(groupContainersNode(at: groupContainer.path, in: result.root))
        let libraryNode = try XCTUnwrap(groupContainersNode(at: libraryDirectory.path, in: result.root))
        let hiddenDirectoryNode = try XCTUnwrap(groupContainersNode(at: hiddenDirectory.path, in: result.root))
        let hiddenFileNode = try XCTUnwrap(groupContainersNode(at: hiddenFile.path, in: result.root))

        XCTAssertNotNil(groupContainersNode(
            at: groupContainer.appendingPathComponent("Library").path,
            in: result.root
        ))
        XCTAssertEqual(libraryNode.children.map(\.name), [".internal-state"])
        XCTAssertTrue(hiddenDirectoryNode.isHidden)
        XCTAssertTrue(hiddenFileNode.isHidden)
        XCTAssertEqual(
            containerNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.directChildCount],
            "1"
        )
    }

    func testPreservesSparseVirtualDiskLogicalAndAllocatedSizes() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        let groupContainer = temporaryDirectory.url
            .appendingPathComponent("group.com.example.virtualizer", isDirectory: true)
        try FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: false)
        let virtualDisk = groupContainer.appendingPathComponent("shared-machine.qcow2")
        XCTAssertTrue(FileManager.default.createFile(atPath: virtualDisk.path, contents: nil))

        let logicalByteCount: UInt64 = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: virtualDisk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let expected = try groupContainersStatValues(for: virtualDisk.path)
        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(groupContainersNode(at: groupContainer.path, in: result.root))
        let diskNode = try XCTUnwrap(groupContainersNode(at: virtualDisk.path, in: result.root))

        XCTAssertEqual(diskNode.ownLogicalSize, expected.logical)
        XCTAssertEqual(diskNode.ownAllocatedSize, expected.allocated)
        XCTAssertEqual(diskNode.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertEqual(
            containerNode.metadata.attributes[GroupContainersAnalyzer.MetadataKey.virtualDiskImageCount],
            "1"
        )

        if diskNode.ownAllocatedSize >= diskNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse virtual disk.")
        }
    }

    func testPermissionDeniedGroupContainerRemainsVisibleWithIssue() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }

        let temporaryDirectory = try GroupContainersTestDirectory()
        let inaccessibleContainer = try makeGroupContainer(
            named: "group.com.example.inaccessible",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        XCTAssertEqual(chmod(inaccessibleContainer.path, 0), 0)
        defer { _ = chmod(inaccessibleContainer.path, mode_t(S_IRWXU)) }

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let inaccessibleNode = try XCTUnwrap(
            groupContainersNode(at: inaccessibleContainer.path, in: result.root)
        )

        XCTAssertEqual(inaccessibleNode.accessibility, .inaccessible)
        XCTAssertTrue(inaccessibleNode.children.isEmpty)
        XCTAssertTrue(inaccessibleNode.scanIssues.contains { $0.kind == .permissionDenied })
        XCTAssertTrue(result.issues.contains {
            $0.path == inaccessibleContainer.path && $0.kind == .permissionDenied
        })
    }

    func testSymbolicLinkIsNotFollowedOrAttributedAsGroupContainer() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        let outsideDirectory = try GroupContainersTestDirectory()
        let outsideFile = outsideDirectory.url.appendingPathComponent("outside.dat")
        try Data(repeating: 0x31, count: 1_048_576).write(to: outsideFile)
        let link = temporaryDirectory.url.appendingPathComponent("group.com.example.external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory.url)

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let linkNode = try XCTUnwrap(groupContainersNode(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertNil(linkNode.metadata.groupContainerIdentifier)
        XCTAssertNil(linkNode.metadata.owningApplications)
        XCTAssertNil(groupContainersNode(at: outsideFile.path, in: result.root))
        XCTAssertLessThan(result.root.logicalSize, 1_048_576)
    }

    func testCancellationReturnsPartialMarkedAnalysis() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()
        for index in 0..<300 {
            try makeGroupContainer(
                named: "group.com.example.application-\(index)",
                fileSize: 64,
                in: temporaryDirectory.url
            )
        }

        let analyzer = makeGroupContainersAnalyzer(
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
        let temporaryDirectory = try GroupContainersTestDirectory()
        let groupContainer = temporaryDirectory.url
            .appendingPathComponent("group.com.example.linked", isDirectory: true)
        try FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: false)
        let original = groupContainer.appendingPathComponent("original.dat")
        let hardLink = groupContainer.appendingPathComponent("linked.dat")
        try Data(repeating: 0x41, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()
        let containerNode = try XCTUnwrap(groupContainersNode(at: groupContainer.path, in: result.root))
        let originalNode = try XCTUnwrap(groupContainersNode(at: original.path, in: result.root))
        let hardLinkNode = try XCTUnwrap(groupContainersNode(at: hardLink.path, in: result.root))
        let linkedNodes = [originalNode, hardLinkNode]
        let countedNode = try XCTUnwrap(linkedNodes.first(where: \.isCountedInParentTotals))

        XCTAssertEqual(linkedNodes.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(
            containerNode.logicalSize,
            containerNode.ownLogicalSize + countedNode.ownLogicalSize
        )
        XCTAssertEqual(
            containerNode.allocatedSize,
            containerNode.ownAllocatedSize + countedNode.ownAllocatedSize
        )
        XCTAssertEqual(result.root.logicalSize, result.root.ownLogicalSize + containerNode.logicalSize)
        XCTAssertEqual(result.root.allocatedSize, result.root.ownAllocatedSize + containerNode.allocatedSize)
    }

    func testEmptyGroupContainersDirectoryReturnsNoEntries() async throws {
        let temporaryDirectory = try GroupContainersTestDirectory()

        let result = await makeGroupContainersAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(result.root.accessibility, .accessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(
            result.root.metadata.attributes[GroupContainersAnalyzer.MetadataKey.directChildCount],
            "0"
        )
    }

    func testMissingGroupContainersDirectoryReturnsUnavailableResult() async {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Missing-Group-Containers-\(UUID().uuidString)", isDirectory: true)

        let result = await makeGroupContainersAnalyzer(root: missingDirectory).analyze()

        XCTAssertEqual(result.root.absolutePath, missingDirectory.standardizedFileURL.path)
        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "group-containers")
    }
}

private final class GroupContainersTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-GroupContainersAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeGroupContainersAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner()
) -> GroupContainersAnalyzer {
    GroupContainersAnalyzer(
        groupContainersURL: root,
        scanner: scanner,
        attributionProvider: { _ in [] }
    )
}

@discardableResult
private func makeGroupContainer(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let groupContainer = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: false)
    try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
        to: groupContainer.appendingPathComponent("payload.dat")
    )
    return groupContainer
}

private func groupContainersNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func groupContainersStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}
