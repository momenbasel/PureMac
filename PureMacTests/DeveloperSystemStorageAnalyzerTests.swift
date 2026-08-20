import Darwin
import XCTest
@testable import PureMac

final class DeveloperSystemStorageAnalyzerTests: XCTestCase {
    func testOptAnalysisPreservesCanonicalIdentity() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "tool", fileSize: 1_024, in: roots.opt)

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(DeveloperSystemStorageAnalyzer.defaultOptURL.path, "/opt")
        XCTAssertEqual(report.opt.canonicalRoot, .opt)
        XCTAssertEqual(report.opt.configuredPath, roots.opt.path)
        XCTAssertEqual(report.opt.state, .present)
        XCTAssertNotNil(node(named: "tool", under: report.opt.result.root))
    }

    func testUsrLocalAnalysisPreservesCanonicalIdentity() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "sdk", fileSize: 1_024, in: roots.usrLocal)

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(DeveloperSystemStorageAnalyzer.defaultUsrLocalURL.path, "/usr/local")
        XCTAssertEqual(report.usrLocal.canonicalRoot, .usrLocal)
        XCTAssertEqual(report.usrLocal.configuredPath, roots.usrLocal.path)
        XCTAssertEqual(report.usrLocal.state, .present)
        XCTAssertNotNil(node(named: "sdk", under: report.usrLocal.result.root))
    }

    func testMissingOptDoesNotFailUsrLocal() async throws {
        let roots = try DeveloperSystemTestRoots(createOpt: false)
        try makeDirectory(named: "bin", fileSize: 512, in: roots.usrLocal)

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(report.opt.state, .missing)
        XCTAssertEqual(report.usrLocal.state, .present)
        XCTAssertNotNil(node(named: "bin", under: report.usrLocal.result.root))
    }

    func testBothMissingRootsRemainSeparate() async throws {
        let roots = try DeveloperSystemTestRoots(createOpt: false, createUsrLocal: false)

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(report.opt.state, .missing)
        XCTAssertEqual(report.usrLocal.state, .missing)
        XCTAssertNotEqual(report.opt.configuredPath, report.usrLocal.configuredPath)
        XCTAssertEqual(report.combinedSizeKnowledge, .complete)
        XCTAssertEqual(
            report.opt.result.root.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.sizeKnowledge],
            DeveloperSystemSizeKnowledge.complete.rawValue
        )
    }

    func testInvalidRootIsReportedWithoutFollowingIt() async throws {
        let roots = try DeveloperSystemTestRoots(createOpt: false)
        try Data([0x01]).write(to: roots.opt)

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(report.opt.state, .invalid)
        XCTAssertEqual(report.opt.result.root.itemType, .regularFile)
        XCTAssertTrue(report.opt.result.issues.contains { $0.kind == .notDirectory })
    }

    func testMultipleImmediateChildrenArePreserved() async throws {
        let roots = try DeveloperSystemTestRoots()
        for name in ["alpha", "beta", "gamma"] {
            try makeDirectory(named: name, fileSize: 1_024, in: roots.opt)
        }

        let report = await roots.analyzer().analyze()

        XCTAssertEqual(Set(report.opt.result.root.children.map(\.name)), Set(["alpha", "beta", "gamma"]))
        XCTAssertEqual(
            report.opt.result.root.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.directChildCount],
            "3"
        )
    }

    func testImmediateChildrenUseAllocatedSizeDescendingOrdering() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "small", fileSize: 4_096, in: roots.opt)
        try makeDirectory(named: "large", fileSize: 2_097_152, in: roots.opt)
        try makeDirectory(named: "medium", fileSize: 262_144, in: roots.opt)

        let children = await roots.analyzer().analyze().opt.result.root.children

        XCTAssertEqual(children.map(\.name), ["large", "medium", "small"])
        XCTAssertTrue(zip(children, children.dropFirst()).allSatisfy {
            allocatedBefore($0, $1)
        })
    }

    func testOptHomebrewReceivesPackageManagerMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "homebrew", fileSize: 1, in: roots.opt)

        let root = await roots.analyzer().analyze().opt.result.root
        let homebrew = try XCTUnwrap(node(named: "homebrew", under: root))

        XCTAssertEqual(homebrew.metadata.storageCategoryIdentifier, DeveloperSystemStorageCategory.packageManagerStorage.rawValue)
        XCTAssertTrue(homebrew.metadata.explanation?.contains("Homebrew") == true)
        XCTAssertNil(homebrew.metadata.safetyClassificationIdentifier)
    }

    func testUsrLocalHomebrewReceivesPackageManagerMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "Homebrew", fileSize: 1, in: roots.usrLocal)

        let root = await roots.analyzer().analyze().usrLocal.result.root
        let homebrew = try XCTUnwrap(node(named: "Homebrew", under: root))

        XCTAssertEqual(homebrew.metadata.storageCategoryIdentifier, DeveloperSystemStorageCategory.packageManagerStorage.rawValue)
        XCTAssertTrue(homebrew.metadata.explanation?.contains("Homebrew") == true)
    }

    func testCellarReceivesPackageManagerMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "Cellar", fileSize: 1, in: roots.usrLocal)

        let root = await roots.analyzer().analyze().usrLocal.result.root
        let cellar = try XCTUnwrap(node(named: "Cellar", under: root))

        XCTAssertEqual(cellar.metadata.storageCategoryIdentifier, DeveloperSystemStorageCategory.packageManagerStorage.rawValue)
        XCTAssertTrue(cellar.metadata.explanation?.contains("formula") == true)
    }

    func testCaskroomReceivesPackageManagerMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "Caskroom", fileSize: 1, in: roots.usrLocal)

        let root = await roots.analyzer().analyze().usrLocal.result.root
        let caskroom = try XCTUnwrap(node(named: "Caskroom", under: root))

        XCTAssertEqual(caskroom.metadata.storageCategoryIdentifier, DeveloperSystemStorageCategory.packageManagerStorage.rawValue)
        XCTAssertTrue(caskroom.metadata.explanation?.contains("Cask") == true)
    }

    func testBinLibAndShareReceiveLightweightCategories() async throws {
        let roots = try DeveloperSystemTestRoots()
        for name in ["bin", "lib", "share"] {
            try makeDirectory(named: name, fileSize: 1, in: roots.usrLocal)
        }

        let root = await roots.analyzer().analyze().usrLocal.result.root

        XCTAssertEqual(node(named: "bin", under: root)?.metadata.storageCategoryIdentifier,
                       DeveloperSystemStorageCategory.executableStorage.rawValue)
        XCTAssertEqual(node(named: "lib", under: root)?.metadata.storageCategoryIdentifier,
                       DeveloperSystemStorageCategory.libraryStorage.rawValue)
        XCTAssertEqual(node(named: "share", under: root)?.metadata.storageCategoryIdentifier,
                       DeveloperSystemStorageCategory.sharedResourceStorage.rawValue)
    }

    func testUnknownEntriesRemainVisibleWithoutGuessedAttribution() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "vendor-product", fileSize: 1, in: roots.opt)

        let root = await roots.analyzer().analyze().opt.result.root
        let unknown = try XCTUnwrap(node(named: "vendor-product", under: root))

        XCTAssertEqual(unknown.metadata.storageCategoryIdentifier, DeveloperSystemStorageCategory.unknown.rawValue)
        XCTAssertNil(unknown.metadata.safetyClassificationIdentifier)
    }

    func testHiddenFilesAndDirectoriesAreIncluded() async throws {
        let roots = try DeveloperSystemTestRoots()
        let hiddenDirectory = roots.opt.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: false)
        let hiddenFile = hiddenDirectory.appendingPathComponent(".state")
        try Data([0x02]).write(to: hiddenFile)

        let root = await roots.analyzer().analyze().opt.result.root

        XCTAssertEqual(node(at: hiddenDirectory.path, in: root)?.isHidden, true)
        XCTAssertEqual(node(at: hiddenFile.path, in: root)?.isHidden, true)
    }

    func testFullHierarchyIsPreserved() async throws {
        let roots = try DeveloperSystemTestRoots()
        let first = roots.opt.appendingPathComponent("tool", isDirectory: true)
        let second = first.appendingPathComponent("sdk", isDirectory: true)
        let third = second.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        try Data([0x03]).write(to: third.appendingPathComponent("manifest"))

        let root = await roots.analyzer().analyze().opt.result.root

        XCTAssertNotNil(node(at: third.path, in: root))
        XCTAssertNotNil(node(at: third.appendingPathComponent("manifest").path, in: root))
    }

    func testLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        let payload = try makeDirectory(named: "tool", fileSize: 32_768, in: roots.opt)
            .appendingPathComponent("payload.dat")
        let expected = try statValues(for: payload.path)

        let root = await roots.analyzer().analyze().opt.result.root
        let scanned = try XCTUnwrap(node(at: payload.path, in: root))

        XCTAssertEqual(scanned.ownLogicalSize, expected.logical)
        XCTAssertEqual(scanned.ownAllocatedSize, expected.allocated)
    }

    func testSparseVirtualDiskPreservesPhysicalDistinctionAndMetadata() async throws {
        let roots = try DeveloperSystemTestRoots()
        let vm = roots.opt.appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: false)
        let disk = vm.appendingPathComponent("machine.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let logicalBytes: UInt64 = 64 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: logicalBytes)
        try handle.close()

        let root = await roots.analyzer().analyze().opt.result.root
        let diskNode = try XCTUnwrap(node(at: disk.path, in: root))
        let vmNode = try XCTUnwrap(node(at: vm.path, in: root))

        XCTAssertEqual(diskNode.ownLogicalSize, Int64(logicalBytes))
        XCTAssertEqual(diskNode.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.virtualDiskFormat], "raw")
        XCTAssertEqual(vmNode.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.virtualDiskImageCount], "1")
        if diskNode.ownAllocatedSize >= diskNode.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse file.")
        }
        XCTAssertEqual(diskNode.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.virtualDiskSparseState], "sparse")
    }

    func testSymlinkBetweenRootsIsVisibleAndNeverFollowed() async throws {
        let roots = try DeveloperSystemTestRoots()
        let homebrew = try makeDirectory(named: "homebrew", fileSize: 1_048_576, in: roots.opt)
        let targetFile = homebrew.appendingPathComponent("payload.dat")
        let alias = roots.usrLocal.appendingPathComponent("Homebrew")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: homebrew)

        let report = await roots.analyzer().analyze()
        let aliasNode = try XCTUnwrap(node(at: alias.path, in: report.usrLocal.result.root))

        XCTAssertTrue(aliasNode.isSymbolicLink)
        XCTAssertEqual(aliasNode.itemType, .symbolicLink)
        XCTAssertTrue(aliasNode.children.isEmpty)
        XCTAssertNil(node(at: targetFile.path, in: report.usrLocal.result.root))
        XCTAssertNotNil(node(at: targetFile.path, in: report.opt.result.root))
    }

    func testHardLinksWithinOneRootAreDeduplicated() async throws {
        let roots = try DeveloperSystemTestRoots()
        let firstDirectory = try makeDirectory(named: "first", fileSize: 0, in: roots.opt)
        let secondDirectory = try makeDirectory(named: "second", fileSize: 0, in: roots.opt)
        let original = firstDirectory.appendingPathComponent("shared")
        let linked = secondDirectory.appendingPathComponent("shared")
        try Data(repeating: 0x04, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        let root = await roots.analyzer().analyze().opt.result.root
        let aliases = try [XCTUnwrap(node(at: original.path, in: root)), XCTUnwrap(node(at: linked.path, in: root))]

        XCTAssertEqual(aliases.filter(\.isCountedInParentTotals).count, 1)
    }

    func testCrossRootHardLinksKeepStandaloneTotalsAndDeduplicateCombinedTotal() async throws {
        let roots = try DeveloperSystemTestRoots()
        let optFile = roots.opt.appendingPathComponent("shared.dat")
        let usrFile = roots.usrLocal.appendingPathComponent("shared.dat")
        try Data(repeating: 0x05, count: 16_384).write(to: optFile)
        try FileManager.default.linkItem(at: optFile, to: usrFile)

        let report = await roots.analyzer().analyze()
        let optNode = try XCTUnwrap(node(at: optFile.path, in: report.opt.result.root))
        let usrNode = try XCTUnwrap(node(at: usrFile.path, in: report.usrLocal.result.root))
        let standaloneAllocated = report.opt.result.root.allocatedSize + report.usrLocal.result.root.allocatedSize
        let standaloneLogical = report.opt.result.root.logicalSize + report.usrLocal.result.root.logicalSize

        XCTAssertTrue(optNode.isCountedInParentTotals)
        XCTAssertTrue(usrNode.isCountedInParentTotals)
        XCTAssertEqual(report.combinedUniqueAllocatedSize, standaloneAllocated - optNode.ownAllocatedSize)
        XCTAssertEqual(report.combinedUniqueLogicalSize, standaloneLogical - optNode.ownLogicalSize)
    }

    func testPermissionDeniedPreservesPOSIXIssue() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A root process can read mode-000 directories.") }
        let roots = try DeveloperSystemTestRoots()
        let protected = try makeDirectory(named: "protected", fileSize: 128, in: roots.opt)
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let report = await roots.analyzer().analyze()
        let protectedNode = try XCTUnwrap(node(at: protected.path, in: report.opt.result.root))
        let issue = try XCTUnwrap(protectedNode.scanIssues.first { $0.kind == .permissionDenied })

        XCTAssertEqual(protectedNode.accessibility, .inaccessible)
        XCTAssertNotNil(issue.posixErrorCode)
    }

    func testUnreadableSubtreeIsMarkedAsKnownLowerBound() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A root process can read mode-000 directories.") }
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "readable", fileSize: 128, in: roots.opt)
        let protected = try makeDirectory(named: "protected", fileSize: 8_192, in: roots.opt)
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let report = await roots.analyzer().analyze()
        let root = report.opt.result.root

        XCTAssertEqual(report.opt.state, .partiallyReadable)
        XCTAssertEqual(root.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.sizeKnowledge],
                       DeveloperSystemSizeKnowledge.knownLowerBound.rawValue)
        XCTAssertGreaterThan(root.allocatedSize, 0)
    }

    func testFilesystemBoundaryIsPreservedAndExcluded() throws {
        let boundaryPath = "/opt/external"
        let boundaryIssue = StorageScanIssue(
            path: boundaryPath,
            kind: .differentVolume,
            message: "Traversal stopped because this item is on a different mounted filesystem.",
            posixErrorCode: nil
        )
        let boundary = syntheticNode(
            name: "external",
            path: boundaryPath,
            itemType: .volumeBoundary,
            accessibility: .skippedDifferentVolume,
            issues: [boundaryIssue],
            isCounted: false,
            ownLogicalSize: 8_192,
            ownAllocatedSize: 8_192
        )
        let optRoot = syntheticNode(name: "opt", path: "/opt", children: [boundary])
        let usrRoot = syntheticNode(name: "local", path: "/usr/local")

        let report = DeveloperSystemStorageAnalyzer.makeReport(
            optResult: syntheticResult(root: optRoot, issues: [boundaryIssue]),
            usrLocalResult: syntheticResult(root: usrRoot),
            combinedUniqueLogicalSize: optRoot.logicalSize + usrRoot.logicalSize,
            combinedUniqueAllocatedSize: optRoot.allocatedSize + usrRoot.allocatedSize,
            largeAllocatedSizeThreshold: 1
        )
        let preserved = try XCTUnwrap(node(at: boundaryPath, in: report.opt.result.root))

        XCTAssertEqual(preserved.accessibility, .skippedDifferentVolume)
        XCTAssertFalse(preserved.isCountedInParentTotals)
        XCTAssertEqual(preserved.metadata.attributes[DeveloperSystemStorageAnalyzer.MetadataKey.sizeKnowledge],
                       DeveloperSystemSizeKnowledge.excludedDifferentVolume.rawValue)
    }

    func testCancellationMarksBothIndependentResults() async throws {
        let roots = try DeveloperSystemTestRoots()
        for index in 0..<300 {
            try makeDirectory(named: "opt-\(index)", fileSize: 32, in: roots.opt)
            try makeDirectory(named: "local-\(index)", fileSize: 32, in: roots.usrLocal)
        }
        let analyzer = roots.analyzer(
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let task = Task { await analyzer.analyze() }
        task.cancel()

        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.issues.contains { $0.kind == .cancelled })
        XCTAssertEqual(report.combinedSizeKnowledge, .incompleteDueToCancellation)
    }

    func testEmptyRootsReturnCompleteSeparateTrees() async throws {
        let roots = try DeveloperSystemTestRoots()

        let report = await roots.analyzer().analyze()

        XCTAssertTrue(report.opt.result.root.children.isEmpty)
        XCTAssertTrue(report.usrLocal.result.root.children.isEmpty)
        XCTAssertEqual(report.opt.state, .present)
        XCTAssertEqual(report.usrLocal.state, .present)
        XCTAssertEqual(report.combinedSizeKnowledge, .complete)
    }

    func testHomebrewExecutableIsNeverInvoked() async throws {
        let roots = try DeveloperSystemTestRoots()
        let homebrew = roots.opt.appendingPathComponent("homebrew", isDirectory: true)
        try FileManager.default.createDirectory(at: homebrew, withIntermediateDirectories: false)
        let marker = roots.base.appendingPathComponent("brew-was-run")
        let fakeBrew = homebrew.appendingPathComponent("brew")
        let script = "#!/bin/sh\ntouch \(marker.path)\n"
        try Data(script.utf8).write(to: fakeBrew)
        XCTAssertEqual(chmod(fakeBrew.path, mode_t(S_IRWXU)), 0)

        _ = await roots.analyzer().analyze()

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAnalysisDoesNotMutateFilesystem() async throws {
        let roots = try DeveloperSystemTestRoots()
        let directory = try makeDirectory(named: "tool", fileSize: 4_096, in: roots.opt)
        let payload = directory.appendingPathComponent("payload.dat")
        let beforeData = try Data(contentsOf: payload)
        let beforeStat = try statValues(for: payload.path)

        _ = await roots.analyzer().analyze()

        XCTAssertEqual(try Data(contentsOf: payload), beforeData)
        XCTAssertEqual(try statValues(for: payload.path), beforeStat)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testAccountingReconcilesPerRootAndCombinedWithoutSharedLinks() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "tool", fileSize: 8_192, in: roots.opt)
        try makeDirectory(named: "bin", fileSize: 16_384, in: roots.usrLocal)

        let report = await roots.analyzer().analyze()

        assertReconciles(report.opt.result.root)
        assertReconciles(report.usrLocal.result.root)
        XCTAssertEqual(report.combinedUniqueLogicalSize,
                       report.opt.result.root.logicalSize + report.usrLocal.result.root.logicalSize)
        XCTAssertEqual(report.combinedUniqueAllocatedSize,
                       report.opt.result.root.allocatedSize + report.usrLocal.result.root.allocatedSize)
    }

    func testRootAndLargeItemMetadataRemainInformational() async throws {
        let roots = try DeveloperSystemTestRoots()
        try makeDirectory(named: "large-vendor", fileSize: 4_096, in: roots.opt)

        let report = await roots.analyzer(largeAllocatedSizeThreshold: 1).analyze()
        let large = try XCTUnwrap(node(named: "large-vendor", under: report.opt.result.root))

        XCTAssertEqual(report.opt.result.root.metadata.storageCategoryIdentifier,
                       DeveloperSystemStorageCategory.thirdPartyStorage.rawValue)
        XCTAssertEqual(report.usrLocal.result.root.metadata.storageCategoryIdentifier,
                       DeveloperSystemStorageCategory.developerToolStorage.rawValue)
        XCTAssertEqual(large.metadata.isUnusuallyLarge, true)
        XCTAssertNil(large.metadata.safetyClassificationIdentifier)
    }
}

private final class DeveloperSystemTestRoots {
    let base: URL
    let opt: URL
    let usrLocal: URL

    init(createOpt: Bool = true, createUsrLocal: Bool = true) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-DeveloperSystem-\(UUID().uuidString)", isDirectory: true)
        opt = base.appendingPathComponent("opt", isDirectory: true)
        usrLocal = base.appendingPathComponent("usr-local", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        if createOpt {
            try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: false)
        }
        if createUsrLocal {
            try FileManager.default.createDirectory(at: usrLocal, withIntermediateDirectories: false)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func analyzer(
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = DeveloperSystemStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) -> DeveloperSystemStorageAnalyzer {
        DeveloperSystemStorageAnalyzer(
            optURL: opt,
            usrLocalURL: usrLocal,
            scanner: scanner,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
        )
    }
}

@discardableResult
private func makeDirectory(named name: String, fileSize: Int, in parent: URL) throws -> URL {
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    if fileSize > 0 {
        try Data(repeating: 0x7A, count: fileSize).write(to: directory.appendingPathComponent("payload.dat"))
    }
    return directory
}

private func node(named name: String, under root: StorageNode) -> StorageNode? {
    root.children.first { $0.name == name }
}

private func node(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let current = pending.popLast() {
        if current.absolutePath == path { return current }
        pending.append(contentsOf: current.children)
    }
    return nil
}

private func allocatedBefore(_ left: StorageNode, _ right: StorageNode) -> Bool {
    if left.allocatedSize != right.allocatedSize { return left.allocatedSize > right.allocatedSize }
    if left.logicalSize != right.logicalSize { return left.logicalSize > right.logicalSize }
    return left.absolutePath < right.absolutePath
}

private struct TestStatValues: Equatable {
    let logical: Int64
    let allocated: Int64
}

private func statValues(for path: String) throws -> TestStatValues {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return TestStatValues(logical: Int64(value.st_size), allocated: Int64(value.st_blocks) * 512)
}

private func assertReconciles(_ node: StorageNode, file: StaticString = #filePath, line: UInt = #line) {
    let childLogical = node.children.reduce(Int64(0)) { $0 + $1.logicalSize }
    let childAllocated = node.children.reduce(Int64(0)) { $0 + $1.allocatedSize }
    let ownLogical = node.isCountedInParentTotals ? node.ownLogicalSize : 0
    let ownAllocated = node.isCountedInParentTotals ? node.ownAllocatedSize : 0
    XCTAssertEqual(node.logicalSize, ownLogical + childLogical, file: file, line: line)
    XCTAssertEqual(node.allocatedSize, ownAllocated + childAllocated, file: file, line: line)
    for child in node.children { assertReconciles(child, file: file, line: line) }
}

private func syntheticNode(
    name: String,
    path: String,
    itemType: StorageItemType = .directory,
    children: [StorageNode] = [],
    accessibility: StorageAccessibility = .accessible,
    issues: [StorageScanIssue] = [],
    isCounted: Bool = true,
    ownLogicalSize: Int64 = 96,
    ownAllocatedSize: Int64 = 4_096
) -> StorageNode {
    let logical = (isCounted ? ownLogicalSize : 0) + children.reduce(Int64(0)) { $0 + $1.logicalSize }
    let allocated = (isCounted ? ownAllocatedSize : 0) + children.reduce(Int64(0)) { $0 + $1.allocatedSize }
    return StorageNode(
        name: name,
        absolutePath: path,
        logicalSize: logical,
        allocatedSize: allocated,
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

private func syntheticResult(
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
