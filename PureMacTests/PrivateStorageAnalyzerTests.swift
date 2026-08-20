import Darwin
import XCTest
@testable import PureMac

final class PrivateStorageAnalyzerTests: XCTestCase {
    func testTopLevelPrivateHierarchyAndCategoriesArePreserved() async throws {
        XCTAssertEqual(PrivateStorageAnalyzer.defaultPrivateURL.path, "/private")
        let temporaryDirectory = try PrivateStorageTestDirectory()
        for name in ["var", "tmp", "etc", "unknown"] {
            try makePrivateDirectory(named: name, fileSize: 1_024, in: temporaryDirectory.url)
        }

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(Set(result.root.children.map(\.name)), Set(["var", "tmp", "etc", "unknown"]))
        XCTAssertEqual(privateNode(named: "var", under: result.root)?.metadata.storageCategoryIdentifier,
                       PrivateStorageCategory.variableState.rawValue)
        XCTAssertEqual(privateNode(named: "tmp", under: result.root)?.metadata.storageCategoryIdentifier,
                       PrivateStorageCategory.temporary.rawValue)
        XCTAssertEqual(privateNode(named: "etc", under: result.root)?.metadata.storageCategoryIdentifier,
                       PrivateStorageCategory.configuration.rawValue)
        XCTAssertEqual(privateNode(named: "unknown", under: result.root)?.metadata.storageCategoryIdentifier,
                       PrivateStorageCategory.otherTopLevel.rawValue)
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "private-storage")
    }

    func testVarDrillDownReusesAndOrdersImmediateChildren() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        try makePrivateDirectory(named: "small", fileSize: 4_096, in: varDirectory)
        try makePrivateDirectory(named: "medium", fileSize: 262_144, in: varDirectory)
        let large = try makePrivateDirectory(named: "large", fileSize: 2_097_152, in: varDirectory)
        let nested = large.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data([0x11]).write(to: nested.appendingPathComponent("state.dat"))

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let varNode = try XCTUnwrap(privateNode(at: varDirectory.path, in: result.root))

        XCTAssertEqual(varNode.children.map(\.name), ["large", "medium", "small"])
        XCTAssertTrue(zip(varNode.children, varNode.children.dropFirst()).allSatisfy {
            privateStorageOrdering($0, $1)
        })
        XCTAssertNotNil(privateNode(at: nested.path, in: result.root))
        XCTAssertEqual(varNode.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.directChildCount], "3")
    }

    func testVarFoldersMetadataExplainsMixedManagedState() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "folders")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.varFolders.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .applicationAndSystemState)
        XCTAssertTrue(node.metadata.explanation?.contains("Per-user and per-process") == true)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testVarVMMetadataIsProtectedSystemState() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "vm")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.varVirtualMemory.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .protectedSystemState)
        XCTAssertTrue(node.metadata.explanation?.contains("virtual-memory") == true)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testVarDatabaseMetadataIsProtectedSystemState() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "db")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.varDatabases.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .protectedSystemState)
        XCTAssertTrue(node.metadata.explanation?.contains("databases") == true)
    }

    func testVarLogMetadataIsAttributionOnly() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "log")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.varLogs.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .systemManaged)
        XCTAssertTrue(node.metadata.explanation?.contains("storage attribution only") == true)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testVarTemporaryMetadataDoesNotImplyCleanup() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "tmp")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.varTemporary.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .temporaryStorage)
        XCTAssertTrue(node.metadata.explanation?.contains("no cleanup behavior") == true)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testUnknownVarChildRemainsVisibleWithoutGuessedClassification() async throws {
        let (_, node) = try await analyzeSingleVarChild(named: "vendor-state")

        XCTAssertEqual(node.metadata.storageCategoryIdentifier, PrivateStorageCategory.otherVarChild.rawValue)
        XCTAssertEqual(privateManagementKind(of: node), .unclassified)
        XCTAssertNil(node.metadata.safetyClassificationIdentifier)
    }

    func testHiddenContentIsIncludedThroughoutPrivateTree() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let hiddenDirectory = varDirectory.appendingPathComponent(".hidden-state", isDirectory: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent(".payload")
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: false)
        try Data(repeating: 0x21, count: 512).write(to: hiddenFile)

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(privateNode(at: hiddenDirectory.path, in: result.root)?.isHidden, true)
        XCTAssertEqual(privateNode(at: hiddenFile.path, in: result.root)?.isHidden, true)
    }

    func testLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let db = try makePrivateDirectory(named: "db", fileSize: 0, in: varDirectory)
        let payload = db.appendingPathComponent("payload.dat")
        try Data(repeating: 0x31, count: 32_768).write(to: payload)
        let expected = try privateStatValues(for: payload.path)

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let node = try XCTUnwrap(privateNode(at: payload.path, in: result.root))

        XCTAssertEqual(node.ownLogicalSize, expected.logical)
        XCTAssertEqual(node.ownAllocatedSize, expected.allocated)
    }

    func testSparseFilePreservesLogicalAllocatedAndVirtualDiskMetadata() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let vm = varDirectory.appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: false)
        let disk = vm.appendingPathComponent("swap-image.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let logicalByteCount: UInt64 = 64 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: logicalByteCount)
        try handle.close()

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let vmNode = try XCTUnwrap(privateNode(at: vm.path, in: result.root))
        let diskNode = try XCTUnwrap(privateNode(at: disk.path, in: result.root))

        XCTAssertEqual(diskNode.ownLogicalSize, Int64(logicalByteCount))
        XCTAssertEqual(diskNode.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.virtualDiskFormat], "raw")
        XCTAssertEqual(vmNode.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.virtualDiskImageCount], "1")
        if diskNode.ownAllocatedSize >= diskNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse file.")
        }
        XCTAssertEqual(
            diskNode.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.virtualDiskSparseState],
            "sparse"
        )
    }

    func testLargeUnknownExtensionFileRemainsOrdinaryVisibleStorage() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let state = varDirectory.appendingPathComponent("mystery-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let largeFile = state.appendingPathComponent("critical.unknown-format")
        try Data(repeating: 0x41, count: 1_048_576).write(to: largeFile)

        let result = await makePrivateStorageAnalyzer(
            root: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1
        ).analyze()
        let stateNode = try XCTUnwrap(privateNode(at: state.path, in: result.root))
        let fileNode = try XCTUnwrap(privateNode(at: largeFile.path, in: result.root))

        XCTAssertEqual(fileNode.itemType, .regularFile)
        XCTAssertGreaterThan(fileNode.logicalSize, 0)
        XCTAssertNil(fileNode.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.virtualDiskFormat])
        XCTAssertNil(fileNode.metadata.safetyClassificationIdentifier)
        XCTAssertEqual(stateNode.metadata.isUnusuallyLarge, true)
    }

    func testSymlinkAliasIsVisibleWithoutFollowingOrDoubleCountingTarget() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let realTmp = try makePrivateDirectory(named: "tmp", fileSize: 1_048_576, in: temporaryDirectory.url)
        let payload = realTmp.appendingPathComponent("payload.dat")
        let alias = temporaryDirectory.url.appendingPathComponent("tmp-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realTmp)

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let aliasNode = try XCTUnwrap(privateNode(at: alias.path, in: result.root))

        XCTAssertEqual(aliasNode.itemType, .symbolicLink)
        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertTrue(aliasNode.children.isEmpty)
        XCTAssertNotNil(privateNode(at: payload.path, in: result.root))
        XCTAssertEqual(aliasNode.metadata.storageCategoryIdentifier, PrivateStorageCategory.otherTopLevel.rawValue)
    }

    func testHardLinksAcrossVarCategoriesAreDeduplicated() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let db = try makePrivateDirectory(named: "db", fileSize: 0, in: varDirectory)
        let log = try makePrivateDirectory(named: "log", fileSize: 0, in: varDirectory)
        let original = db.appendingPathComponent("shared-state")
        let linked = log.appendingPathComponent("shared-state")
        try Data(repeating: 0x51, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let aliases = try [
            XCTUnwrap(privateNode(at: original.path, in: result.root)),
            XCTUnwrap(privateNode(at: linked.path, in: result.root)),
        ]

        XCTAssertEqual(aliases.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(aliases[0].ownLogicalSize, aliases[1].ownLogicalSize)
        XCTAssertEqual(aliases[0].ownAllocatedSize, aliases[1].ownAllocatedSize)
    }

    func testEnrichmentPreservesFilesystemBoundaryAndExcludesItsBytes() throws {
        let boundaryPath = "/private/var/external"
        let boundaryIssue = StorageScanIssue(
            path: boundaryPath,
            kind: .differentVolume,
            message: "Traversal stopped because this item is on a different mounted filesystem.",
            posixErrorCode: nil
        )
        let boundary = syntheticPrivateNode(
            name: "external",
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
        let varNode = syntheticPrivateNode(
            name: "var",
            path: "/private/var",
            logicalSize: 96,
            allocatedSize: 4_096,
            ownLogicalSize: 96,
            ownAllocatedSize: 4_096,
            itemType: .directory,
            children: [boundary]
        )
        let root = syntheticPrivateNode(
            name: "private",
            path: "/private",
            logicalSize: 192,
            allocatedSize: 8_192,
            ownLogicalSize: 96,
            ownAllocatedSize: 4_096,
            itemType: .directory,
            children: [varNode]
        )
        let input = syntheticPrivateResult(root: root, issues: [boundaryIssue])

        let result = PrivateStorageAnalyzer.enrich(input, largeAllocatedSizeThreshold: 1)
        let preserved = try XCTUnwrap(privateNode(at: boundaryPath, in: result.root))

        XCTAssertEqual(preserved.itemType, .volumeBoundary)
        XCTAssertEqual(preserved.accessibility, .skippedDifferentVolume)
        XCTAssertFalse(preserved.isCountedInParentTotals)
        XCTAssertEqual(privateSizeKnowledge(of: preserved), .excludedDifferentVolume)
        XCTAssertEqual(result.root.logicalSize, 192)
        XCTAssertEqual(result.root.allocatedSize, 8_192)
    }

    func testPermissionDeniedNodePreservesIssueAndPOSIXCode() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A root process can read mode-000 directories.") }
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let protected = try makePrivateDirectory(named: "protected", fileSize: 128, in: varDirectory)
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let protectedNode = try XCTUnwrap(privateNode(at: protected.path, in: result.root))
        let issue = try XCTUnwrap(protectedNode.scanIssues.first { $0.kind == .permissionDenied })

        XCTAssertEqual(protectedNode.accessibility, .inaccessible)
        XCTAssertNotNil(issue.posixErrorCode)
        XCTAssertTrue(result.issues.contains { $0.path == protected.path && $0.kind == .permissionDenied })
    }

    func testPermissionFailurePropagatesPartialAccessibilityToAncestors() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A root process can read mode-000 directories.") }
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        try makePrivateDirectory(named: "readable", fileSize: 128, in: varDirectory)
        let inaccessible = try makePrivateDirectory(named: "root", fileSize: 128, in: varDirectory)
        XCTAssertEqual(chmod(inaccessible.path, 0), 0)
        defer { _ = chmod(inaccessible.path, mode_t(S_IRWXU)) }

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let varNode = try XCTUnwrap(privateNode(at: varDirectory.path, in: result.root))

        XCTAssertEqual(varNode.accessibility, .partiallyAccessible)
        XCTAssertEqual(result.root.accessibility, .partiallyAccessible)
        XCTAssertEqual(privateSizeKnowledge(of: varNode), .incompleteDueToInaccessibility)
        XCTAssertNotNil(privateNode(at: varDirectory.appendingPathComponent("readable/payload.dat").path,
                                    in: result.root))
    }

    func testUnknownDescendantSizeIsDistinctFromAccessibleTrueZero() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A root process can read mode-000 directories.") }
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let folders = varDirectory.appendingPathComponent("folders", isDirectory: true)
        let protected = varDirectory.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: folders, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false)
        let emptyFile = folders.appendingPathComponent("known-zero")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyFile.path, contents: nil))
        try Data(repeating: 0x61, count: 8_192).write(to: protected.appendingPathComponent("unknown.dat"))
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let zeroNode = try XCTUnwrap(privateNode(at: emptyFile.path, in: result.root))
        let unknownNode = try XCTUnwrap(privateNode(at: protected.path, in: result.root))

        XCTAssertEqual(zeroNode.ownLogicalSize, 0)
        XCTAssertEqual(zeroNode.accessibility, .accessible)
        XCTAssertEqual(privateSizeKnowledge(of: zeroNode), .complete)
        XCTAssertEqual(unknownNode.accessibility, .inaccessible)
        XCTAssertEqual(privateSizeKnowledge(of: unknownNode), .incompleteDueToInaccessibility)
        XCTAssertTrue(unknownNode.scanIssues.contains { $0.kind == .permissionDenied })
    }

    func testCancellationReturnsPartialMarkedAnalysis() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        for index in 0..<300 {
            try makePrivateDirectory(named: "state-\(index)", fileSize: 64, in: varDirectory)
        }
        let analyzer = makePrivateStorageAnalyzer(
            root: temporaryDirectory.url,
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let task = Task { await analyzer.analyze() }
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
        XCTAssertNotEqual(result.root.accessibility, .accessible)
        XCTAssertEqual(privateSizeKnowledge(of: result.root), .incompleteDueToCancellation)
    }

    func testEmptyRootReturnsAccessibleZeroChildAnalysis() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()

        XCTAssertEqual(result.root.itemType, .directory)
        XCTAssertEqual(result.root.accessibility, .accessible)
        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(result.root.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.directChildCount], "0")
        XCTAssertEqual(privateSizeKnowledge(of: result.root), .complete)
    }

    func testMissingRootReturnsTypedUnavailableAnalysis() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-Missing-Private-\(UUID().uuidString)", isDirectory: true)

        let result = await makePrivateStorageAnalyzer(root: missing).analyze()

        XCTAssertEqual(result.root.itemType, .unknown)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.issues.contains { $0.kind == .metadataUnavailable })
        XCTAssertEqual(privateSizeKnowledge(of: result.root), .incompleteDueToInaccessibility)
    }

    func testNonDirectoryRootReturnsTypedIssue() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let file = temporaryDirectory.url.appendingPathComponent("private-file")
        try Data([0x71]).write(to: file)

        let result = await makePrivateStorageAnalyzer(root: file).analyze()

        XCTAssertEqual(result.root.itemType, .regularFile)
        XCTAssertEqual(result.root.accessibility, .inaccessible)
        XCTAssertTrue(result.issues.contains {
            $0.kind == .notDirectory && $0.posixErrorCode == ENOTDIR
        })
    }

    func testAccountingReconcilesToSingleCanonicalTree() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        try makePrivateDirectory(named: "folders", fileSize: 8_192, in: varDirectory)
        try makePrivateDirectory(named: "db", fileSize: 16_384, in: varDirectory)
        try makePrivateDirectory(named: "tmp", fileSize: 32_768, in: temporaryDirectory.url)

        let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
        let counted = flattenedPrivateTree(result.root).filter(\.isCountedInParentTotals)

        XCTAssertEqual(result.root.logicalSize,
                       counted.reduce(Int64(0)) { $0 + $1.ownLogicalSize })
        XCTAssertEqual(result.root.allocatedSize,
                       counted.reduce(Int64(0)) { $0 + $1.ownAllocatedSize })
        XCTAssertEqual(result.root.logicalSize,
                       result.root.ownLogicalSize + result.root.children.reduce(0) { $0 + $1.logicalSize })
        XCTAssertEqual(result.root.allocatedSize,
                       result.root.ownAllocatedSize + result.root.children.reduce(0) { $0 + $1.allocatedSize })
    }

    func testVarDrillDownMetadataDoesNotAddBytesAgain() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        try makePrivateDirectory(named: "folders", fileSize: 8_192, in: varDirectory)
        try makePrivateDirectory(named: "vm", fileSize: 16_384, in: varDirectory)
        let scanner = FileTreeScanner()
        let raw = await scanner.scan(root: temporaryDirectory.url)

        let enriched = PrivateStorageAnalyzer.enrich(raw, largeAllocatedSizeThreshold: 1)
        let varNode = try XCTUnwrap(privateNode(at: varDirectory.path, in: enriched.root))

        XCTAssertEqual(enriched.root.logicalSize, raw.root.logicalSize)
        XCTAssertEqual(enriched.root.allocatedSize, raw.root.allocatedSize)
        XCTAssertEqual(varNode.logicalSize,
                       varNode.ownLogicalSize + varNode.children.reduce(0) { $0 + $1.logicalSize })
        XCTAssertEqual(varNode.allocatedSize,
                       varNode.ownAllocatedSize + varNode.children.reduce(0) { $0 + $1.allocatedSize })
    }

    func testAnalysisDoesNotMutateOrDeleteContents() async throws {
        let temporaryDirectory = try PrivateStorageTestDirectory()
        let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
        let db = varDirectory.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: false)
        let importantFile = db.appendingPathComponent("critical-state.db")
        let originalData = Data(repeating: 0x81, count: 4_096)
        try originalData.write(to: importantFile)
        let originalMode = try privateStatMode(for: importantFile.path)

        _ = await makePrivateStorageAnalyzer(
            root: temporaryDirectory.url,
            largeAllocatedSizeThreshold: 1
        ).analyze()

        XCTAssertTrue(FileManager.default.fileExists(atPath: importantFile.path))
        XCTAssertEqual(try Data(contentsOf: importantFile), originalData)
        XCTAssertEqual(try privateStatMode(for: importantFile.path), originalMode)
    }
}

private final class PrivateStorageTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-PrivateStorageAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makePrivateStorageAnalyzer(
    root: URL,
    scanner: FileTreeScanner = FileTreeScanner(),
    largeAllocatedSizeThreshold: Int64 = PrivateStorageAnalyzer.defaultLargeAllocatedSizeThreshold
) -> PrivateStorageAnalyzer {
    PrivateStorageAnalyzer(
        privateURL: root,
        scanner: scanner,
        largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
    )
}

private func makeVarDirectory(in root: URL) throws -> URL {
    let varDirectory = root.appendingPathComponent("var", isDirectory: true)
    try FileManager.default.createDirectory(at: varDirectory, withIntermediateDirectories: false)
    return varDirectory
}

@discardableResult
private func makePrivateDirectory(
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

private func analyzeSingleVarChild(
    named name: String
) async throws -> (PrivateStorageTestDirectory, StorageNode) {
    let temporaryDirectory = try PrivateStorageTestDirectory()
    let varDirectory = try makeVarDirectory(in: temporaryDirectory.url)
    let child = try makePrivateDirectory(named: name, fileSize: 1_024, in: varDirectory)
    let result = await makePrivateStorageAnalyzer(root: temporaryDirectory.url).analyze()
    return (temporaryDirectory, try XCTUnwrap(privateNode(at: child.path, in: result.root)))
}

private func privateNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func privateNode(named name: String, under root: StorageNode) -> StorageNode? {
    root.children.first { $0.name == name }
}

private func flattenedPrivateTree(_ root: StorageNode) -> [StorageNode] {
    var result: [StorageNode] = []
    var pending = [root]
    while let node = pending.popLast() {
        result.append(node)
        pending.append(contentsOf: node.children)
    }
    return result
}

private func privateStorageOrdering(_ left: StorageNode, _ right: StorageNode) -> Bool {
    if left.allocatedSize != right.allocatedSize { return left.allocatedSize > right.allocatedSize }
    if left.logicalSize != right.logicalSize { return left.logicalSize > right.logicalSize }
    return left.absolutePath < right.absolutePath
}

private func privateManagementKind(of node: StorageNode) -> PrivateStorageManagementKind? {
    node.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.managementKind]
        .flatMap(PrivateStorageManagementKind.init(rawValue:))
}

private func privateSizeKnowledge(of node: StorageNode) -> PrivateStorageSizeKnowledge? {
    node.metadata.attributes[PrivateStorageAnalyzer.MetadataKey.sizeKnowledge]
        .flatMap(PrivateStorageSizeKnowledge.init(rawValue:))
}

private func syntheticPrivateResult(
    root: StorageNode,
    issues: [StorageScanIssue] = []
) -> StorageAnalysisResult {
    StorageAnalysisResult(
        root: root,
        startedAt: Date(),
        completedAt: Date(),
        rootDeviceIdentifier: 1,
        wasCancelled: false,
        issues: issues
    )
}

private func syntheticPrivateNode(
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

private func privateStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (Int64(metadata.st_size), Int64(metadata.st_blocks) * 512)
}

private func privateStatMode(for path: String) throws -> mode_t {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return metadata.st_mode
}
