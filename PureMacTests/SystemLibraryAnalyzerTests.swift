import Darwin
import XCTest
@testable import PureMac

final class SystemLibraryAnalyzerTests: XCTestCase {
    func testAnalyzesMultipleTopLevelDirectoriesAndSortsByAllocatedSize() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        try makeSystemLibraryDirectory(named: "Small", fileSize: 4_096, in: temporaryDirectory.url)
        try makeSystemLibraryDirectory(named: "Medium", fileSize: 262_144, in: temporaryDirectory.url)
        try makeSystemLibraryDirectory(named: "Large", fileSize: 2_097_152, in: temporaryDirectory.url)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let entries = result.root.children

        XCTAssertEqual(entries.map(\.name), ["Large", "Medium", "Small"])
        XCTAssertTrue(zip(entries, entries.dropFirst()).allSatisfy {
            systemLibraryOrdering($0, $1)
        })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "system-library")
        XCTAssertEqual(
            result.root.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.directChildCount],
            "3"
        )
    }

    func testPreservesCompleteHierarchyAndHiddenEntries() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let developer = temporaryDirectory.url.appendingPathComponent("Developer", isDirectory: true)
        let nested = developer
            .appendingPathComponent("SDKs", isDirectory: true)
            .appendingPathComponent("Nested", isDirectory: true)
        let hiddenDirectory = nested.appendingPathComponent(".metadata", isDirectory: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent(".index")
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 2_048).write(to: hiddenFile)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertNotNil(systemLibraryNode(at: developer.path, in: result.root))
        XCTAssertNotNil(systemLibraryNode(at: nested.path, in: result.root))
        XCTAssertEqual(systemLibraryNode(at: hiddenDirectory.path, in: result.root)?.isHidden, true)
        XCTAssertEqual(systemLibraryNode(at: hiddenFile.path, in: result.root)?.isHidden, true)
        XCTAssertEqual(
            systemLibraryNode(at: developer.path, in: result.root)?.metadata.storageCategoryIdentifier,
            SystemLibraryStorageCategory.developer.rawValue
        )
    }

    func testAddsTypedMetadataForKnownSystemLibraryCategories() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let expected: [(String, SystemLibraryStorageCategory)] = [
            ("Application Support", .applicationSupport),
            ("Caches", .caches),
            ("Developer", .developer),
            ("Logs", .logs),
            ("Frameworks", .frameworks),
            ("LaunchAgents", .launchAgents),
            ("LaunchDaemons", .launchDaemons),
            ("PrivilegedHelperTools", .privilegedHelperTools),
            ("Preferences", .preferences),
            ("Extensions", .extensions),
            ("Updates", .updates),
            ("Audio", .audio),
            ("Fonts", .fonts),
        ]
        for (name, _) in expected {
            try FileManager.default.createDirectory(
                at: temporaryDirectory.url.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()

        for (name, category) in expected {
            let path = temporaryDirectory.url.appendingPathComponent(name).path
            let node = try XCTUnwrap(systemLibraryNode(at: path, in: result.root))
            XCTAssertEqual(node.metadata.storageCategoryIdentifier, category.rawValue)
            XCTAssertEqual(node.metadata.explanation, category.explanation)
            XCTAssertEqual(
                node.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.storageScope],
                "system-wide"
            )
            XCTAssertNil(node.metadata.safetyClassificationIdentifier)
        }
    }

    func testUnknownTopLevelDirectoryRemainsVisibleAsOtherStorage() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let unknown = try makeSystemLibraryDirectory(
            named: "VendorSpecificData",
            fileSize: 1_024,
            in: temporaryDirectory.url
        )

        let result = await makeSystemLibraryAnalyzer(
            root: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1
        ).analyze()
        let node = try XCTUnwrap(systemLibraryNode(at: unknown.path, in: result.root))

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, SystemLibraryStorageCategory.other.rawValue)
        XCTAssertTrue(node.metadata.explanation?.contains("Other storage") == true)
        XCTAssertEqual(node.metadata.isUnusuallyLarge, true)
        XCTAssertEqual(
            node.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.largeAllocatedSizeThreshold],
            "1"
        )
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testSystemWideApplicationSupportIsDistinctFromUserApplicationSupport() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let applicationSupport = try makeSystemLibraryDirectory(
            named: "Application Support",
            fileSize: 4_096,
            in: temporaryDirectory.url
        )

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(systemLibraryNode(at: applicationSupport.path, in: result.root))

        XCTAssertEqual(
            node.metadata.storageCategoryIdentifier,
            SystemLibraryStorageCategory.applicationSupport.rawValue
        )
        XCTAssertNotEqual(
            node.metadata.storageCategoryIdentifier,
            ApplicationSupportAnalyzer.storageCategoryIdentifier
        )
        XCTAssertTrue(node.metadata.explanation?.contains("System-wide shared application data") == true)
        XCTAssertEqual(
            node.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.storageScope],
            "system-wide"
        )
    }

    func testLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let caches = temporaryDirectory.url.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        let payload = caches.appendingPathComponent("cache.dat")
        try Data(repeating: 0x21, count: 32_768).write(to: payload)
        let expected = try systemLibraryStatValues(for: payload.path)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(systemLibraryNode(at: payload.path, in: result.root))

        XCTAssertEqual(node.ownLogicalSize, expected.logical)
        XCTAssertEqual(node.ownAllocatedSize, expected.allocated)
    }

    func testSparseVirtualDiskPreservesSizesAndSparseMetadata() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let applicationSupport = temporaryDirectory.url
            .appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: false)
        let virtualDisk = applicationSupport.appendingPathComponent("machine.qcow2")
        XCTAssertTrue(FileManager.default.createFile(atPath: virtualDisk.path, contents: nil))
        let logicalByteCount: UInt64 = 64 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: virtualDisk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let parent = try XCTUnwrap(systemLibraryNode(at: applicationSupport.path, in: result.root))
        let disk = try XCTUnwrap(systemLibraryNode(at: virtualDisk.path, in: result.root))

        XCTAssertEqual(disk.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertEqual(
            disk.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskFormat],
            "qcow2"
        )
        XCTAssertEqual(
            parent.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskImageCount],
            "1"
        )
        if disk.ownAllocatedSize >= disk.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse virtual disk.")
        }
        XCTAssertEqual(
            disk.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskSparseState],
            "sparse"
        )
    }

    func testRecognizesAllSupportedVirtualDiskFormatsWithoutInspectingContents() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let support = temporaryDirectory.url.appendingPathComponent("VM Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let expected = ["raw", "img", "qcow2", "vmdk"]
        for pathExtension in expected {
            try Data([0x31]).write(to: support.appendingPathComponent("disk.\(pathExtension)"))
        }
        let sparseBundle = support.appendingPathComponent("disk.sparsebundle", isDirectory: true)
        try FileManager.default.createDirectory(at: sparseBundle, withIntermediateDirectories: false)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let supportNode = try XCTUnwrap(systemLibraryNode(at: support.path, in: result.root))

        for pathExtension in expected {
            let path = support.appendingPathComponent("disk.\(pathExtension)").path
            XCTAssertEqual(
                systemLibraryNode(at: path, in: result.root)?
                    .metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskFormat],
                pathExtension
            )
        }
        XCTAssertEqual(
            systemLibraryNode(at: sparseBundle.path, in: result.root)?
                .metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskFormat],
            "sparsebundle"
        )
        XCTAssertEqual(
            supportNode.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.virtualDiskImageCount],
            "5"
        )
    }

    func testSymbolicLinksRemainVisibleAndAreNeverFollowed() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let outsideDirectory = try SystemLibraryTestDirectory()
        let outsideFile = outsideDirectory.url.appendingPathComponent("outside.raw")
        try Data(repeating: 0x41, count: 1_048_576).write(to: outsideFile)
        let link = temporaryDirectory.url.appendingPathComponent("Caches")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory.url)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let linkNode = try XCTUnwrap(systemLibraryNode(at: link.path, in: result.root))

        XCTAssertEqual(linkNode.itemType, .symbolicLink)
        XCTAssertTrue(linkNode.isSymbolicLink)
        XCTAssertTrue(linkNode.children.isEmpty)
        XCTAssertEqual(linkNode.metadata.storageCategoryIdentifier, SystemLibraryStorageCategory.other.rawValue)
        XCTAssertNil(systemLibraryNode(at: outsideFile.path, in: result.root))
    }

    func testEnrichmentPreservesScannerVolumeBoundaryWithoutCountingItsBytes() throws {
        let rootPath = "/Library"
        let boundaryPath = "/Library/ExternalVolume"
        let boundaryIssue = StorageScanIssue(
            path: boundaryPath,
            kind: .differentVolume,
            message: "Traversal stopped because this item is on a different mounted filesystem.",
            posixErrorCode: nil
        )
        let boundary = syntheticSystemLibraryNode(
            name: "ExternalVolume",
            path: boundaryPath,
            logicalSize: 0,
            allocatedSize: 0,
            ownLogicalSize: 8_192,
            ownAllocatedSize: 8_192,
            itemType: .volumeBoundary,
            accessibility: .skippedDifferentVolume,
            issues: [boundaryIssue],
            isCounted: false
        )
        let root = syntheticSystemLibraryNode(
            name: "Library",
            path: rootPath,
            logicalSize: 128,
            allocatedSize: 4_096,
            ownLogicalSize: 128,
            ownAllocatedSize: 4_096,
            itemType: .directory,
            children: [boundary]
        )
        let input = StorageAnalysisResult(
            root: root,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: [boundaryIssue]
        )

        let result = SystemLibraryAnalyzer.enrich(input, largeAllocatedSizeThreshold: 1)
        let preserved = try XCTUnwrap(result.root.children.first)

        XCTAssertEqual(preserved.itemType, .volumeBoundary)
        XCTAssertEqual(preserved.accessibility, .skippedDifferentVolume)
        XCTAssertFalse(preserved.isCountedInParentTotals)
        XCTAssertEqual(result.root.logicalSize, 128)
        XCTAssertEqual(result.root.allocatedSize, 4_096)
        XCTAssertTrue(result.issues.contains { $0.kind == .differentVolume })
    }

    func testPermissionDeniedChildProducesPartialResultAndPreservesPOSIXError() async throws {
        guard geteuid() != 0 else {
            throw XCTSkip("A root process can read mode-000 test directories.")
        }
        let temporaryDirectory = try SystemLibraryTestDirectory()
        try makeSystemLibraryDirectory(named: "Readable", fileSize: 128, in: temporaryDirectory.url)
        let inaccessible = try makeSystemLibraryDirectory(
            named: "PrivilegedHelperTools",
            fileSize: 128,
            in: temporaryDirectory.url
        )
        XCTAssertEqual(chmod(inaccessible.path, 0), 0)
        defer { _ = chmod(inaccessible.path, mode_t(S_IRWXU)) }

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let inaccessibleNode = try XCTUnwrap(systemLibraryNode(at: inaccessible.path, in: result.root))
        let issue = try XCTUnwrap(inaccessibleNode.scanIssues.first { $0.kind == .permissionDenied })

        XCTAssertEqual(inaccessibleNode.accessibility, .inaccessible)
        XCTAssertTrue(inaccessibleNode.children.isEmpty)
        XCTAssertNotNil(issue.posixErrorCode)
        XCTAssertEqual(result.root.accessibility, .partiallyAccessible)
        XCTAssertNotNil(systemLibraryNode(
            at: temporaryDirectory.url.appendingPathComponent("Readable/payload.dat").path,
            in: result.root
        ))
    }

    func testCancellationReturnsAVisiblePartialMarkedTree() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        for index in 0..<300 {
            try makeSystemLibraryDirectory(
                named: "Component-\(index)",
                fileSize: 64,
                in: temporaryDirectory.url
            )
        }
        let analyzer = makeSystemLibraryAnalyzer(
            root: temporaryDirectory.url,
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let task = Task { await analyzer.analyze() }
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
        XCTAssertNotEqual(result.root.accessibility, .accessible)
    }

    func testEmptyRootReturnsAnAccessibleEmptyAnalysis() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(result.root.accessibility, .accessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(
            result.root.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.directChildCount],
            "0"
        )
    }

    func testMissingRootReturnsTypedUnavailableAnalysis() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Missing-System-Library-\(UUID().uuidString)", isDirectory: true)

        let result = await makeSystemLibraryAnalyzer(root: missing).analyze()

        XCTAssertEqual(result.root.absolutePath, missing.standardizedFileURL.path)
        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "system-library")
    }

    func testNonDirectoryRootReturnsTypedNotDirectoryIssue() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let file = temporaryDirectory.url.appendingPathComponent("Library-file")
        try Data([0x51]).write(to: file)

        let result = await makeSystemLibraryAnalyzer(root: file).analyze()

        XCTAssertEqual(result.root.itemType, .regularFile)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.root.scanIssues.contains {
            $0.kind == .notDirectory && $0.posixErrorCode == ENOTDIR
        })
        XCTAssertTrue(result.issues.contains { $0.kind == .notDirectory })
    }

    func testAccountingReconcilesToOneCanonicalTree() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        try makeSystemLibraryDirectory(named: "Caches", fileSize: 8_192, in: temporaryDirectory.url)
        try makeSystemLibraryDirectory(named: "Logs", fileSize: 16_384, in: temporaryDirectory.url)
        try makeSystemLibraryDirectory(
            named: "Application Support",
            fileSize: 32_768,
            in: temporaryDirectory.url
        )

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let counted = flattenedSystemLibraryTree(result.root).filter(\.isCountedInParentTotals)
        let logical = counted.reduce(Int64(0)) { $0 + $1.ownLogicalSize }
        let allocated = counted.reduce(Int64(0)) { $0 + $1.ownAllocatedSize }

        XCTAssertEqual(result.root.logicalSize, logical)
        XCTAssertEqual(result.root.allocatedSize, allocated)
        XCTAssertEqual(
            result.root.logicalSize,
            result.root.ownLogicalSize + result.root.children.reduce(0) { $0 + $1.logicalSize }
        )
        XCTAssertEqual(
            result.root.allocatedSize,
            result.root.ownAllocatedSize + result.root.children.reduce(0) { $0 + $1.allocatedSize }
        )
        XCTAssertTrue(result.root.children.allSatisfy {
            $0.logicalSize <= result.root.logicalSize && $0.allocatedSize <= result.root.allocatedSize
        })
    }

    func testHardLinkedBytesAcrossConceptualCategoriesAreCountedOnlyOnce() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let caches = temporaryDirectory.url.appendingPathComponent("Caches", isDirectory: true)
        let logs = temporaryDirectory.url.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let original = caches.appendingPathComponent("shared.dat")
        let linked = logs.appendingPathComponent("shared.dat")
        try Data(repeating: 0x61, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()
        let originalNode = try XCTUnwrap(systemLibraryNode(at: original.path, in: result.root))
        let linkedNode = try XCTUnwrap(systemLibraryNode(at: linked.path, in: result.root))
        let aliases = [originalNode, linkedNode]
        let countedNode = try XCTUnwrap(aliases.first(where: \.isCountedInParentTotals))

        XCTAssertEqual(aliases.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(
            systemLibraryNode(at: caches.path, in: result.root)?.metadata.storageCategoryIdentifier,
            SystemLibraryStorageCategory.caches.rawValue
        )
        XCTAssertEqual(
            systemLibraryNode(at: logs.path, in: result.root)?.metadata.storageCategoryIdentifier,
            SystemLibraryStorageCategory.logs.rawValue
        )
        XCTAssertEqual(
            result.root.logicalSize,
            result.root.ownLogicalSize
                + systemLibraryNode(at: caches.path, in: result.root)!.ownLogicalSize
                + systemLibraryNode(at: logs.path, in: result.root)!.ownLogicalSize
                + countedNode.ownLogicalSize
        )
    }

    func testCanonicalPathIsPreservedWithoutDataVolumeRewriting() async throws {
        XCTAssertEqual(SystemLibraryAnalyzer.defaultSystemLibraryURL.path, "/Library")
        let temporaryDirectory = try SystemLibraryTestDirectory()

        let result = await makeSystemLibraryAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.absolutePath, temporaryDirectory.url.standardizedFileURL.path)
        XCTAssertEqual(
            result.root.metadata.attributes[SystemLibraryAnalyzer.MetadataKey.canonicalUserFacingPath],
            temporaryDirectory.url.standardizedFileURL.path
        )
        XCTAssertFalse(result.root.absolutePath.contains("/System/Volumes/Data"))
    }

    func testAnalysisDoesNotDeleteOrModifyFilesystemContents() async throws {
        let temporaryDirectory = try SystemLibraryTestDirectory()
        let logs = temporaryDirectory.url.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let file = logs.appendingPathComponent("important.log")
        let originalData = Data(repeating: 0x71, count: 4_096)
        try originalData.write(to: file)
        let originalMode = try systemLibraryStatMode(for: file.path)

        _ = await makeSystemLibraryAnalyzer(
            root: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1
        ).analyze()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        XCTAssertEqual(try systemLibraryStatMode(for: file.path), originalMode)
    }
}

private final class SystemLibraryTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-SystemLibraryAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeSystemLibraryAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner(),
    largeAllocatedSizeThreshold: Int64 = SystemLibraryAnalyzer.defaultLargeAllocatedSizeThreshold
) -> SystemLibraryAnalyzer {
    SystemLibraryAnalyzer(
        systemLibraryURL: root,
        scanner: scanner,
        largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
    )
}

@discardableResult
private func makeSystemLibraryDirectory(
    named name: String,
    fileSize: Int,
    in root: URL
) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
        to: directory.appendingPathComponent("payload.dat")
    )
    return directory
}

private func systemLibraryNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func flattenedSystemLibraryTree(_ root: StorageNode) -> [StorageNode] {
    var nodes: [StorageNode] = []
    var pending = [root]
    while let node = pending.popLast() {
        nodes.append(node)
        pending.append(contentsOf: node.children)
    }
    return nodes
}

private func systemLibraryOrdering(_ left: StorageNode, _ right: StorageNode) -> Bool {
    if left.allocatedSize != right.allocatedSize {
        return left.allocatedSize > right.allocatedSize
    }
    if left.logicalSize != right.logicalSize {
        return left.logicalSize > right.logicalSize
    }
    return left.absolutePath < right.absolutePath
}

private func syntheticSystemLibraryNode(
    name: String,
    path: String,
    logicalSize: Int64,
    allocatedSize: Int64,
    ownLogicalSize: Int64,
    ownAllocatedSize: Int64,
    itemType: StorageItemType,
    children: [StorageNode] = [],
    accessibility: StorageAccessibility = .accessible,
    issues: [StorageScanIssue] = [],
    isCounted: Bool = true
) -> StorageNode {
    StorageNode(
        name: name,
        absolutePath: path,
        logicalSize: logicalSize,
        allocatedSize: allocatedSize,
        ownLogicalSize: ownLogicalSize,
        ownAllocatedSize: ownAllocatedSize,
        itemType: itemType,
        children: children,
        accessibility: accessibility,
        scanIssues: issues,
        isHidden: false,
        isSymbolicLink: false,
        isCountedInParentTotals: isCounted,
        metadata: StorageAnalysisMetadata()
    )
}

private func systemLibraryStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (
        logical: Int64(metadata.st_size),
        allocated: Int64(metadata.st_blocks) * 512
    )
}

private func systemLibraryStatMode(for path: String) throws -> mode_t {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return metadata.st_mode
}
