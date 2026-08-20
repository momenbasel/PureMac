import Darwin
import XCTest
@testable import PureMac

final class UserHomeStorageAnalyzerTests: XCTestCase {
    func testDesktopIsAnalyzed() async throws {
        try await assertStandardDirectory(.desktop)
    }

    func testDocumentsIsAnalyzed() async throws {
        try await assertStandardDirectory(.documents)
    }

    func testDownloadsIsAnalyzed() async throws {
        try await assertStandardDirectory(.downloads)
    }

    func testMoviesIsAnalyzed() async throws {
        try await assertStandardDirectory(.movies)
    }

    func testMusicIsAnalyzed() async throws {
        try await assertStandardDirectory(.music)
    }

    func testPicturesIsAnalyzed() async throws {
        try await assertStandardDirectory(.pictures)
    }

    func testPublicIsAnalyzed() async throws {
        try await assertStandardDirectory(.public)
    }

    func testCustomVisibleHomeFolderIsAnalyzedWithoutCleanupClassification() async throws {
        let home = try UserHomeTestDirectory()
        let projects = try makeFolder(named: "Projects", fileSize: 4_096, in: home.url)

        let report = await makeAnalyzer(home: home.url).analyze()
        let root = try XCTUnwrap(report.roots.first { $0.node.absolutePath == projects.path })

        XCTAssertNil(root.standardDirectory)
        XCTAssertEqual(root.node.metadata.attributes[UserHomeStorageAnalyzer.MetadataKey.rootKind], "custom")
        XCTAssertNil(root.node.metadata.safetyClassificationIdentifier)
        XCTAssertTrue(root.node.metadata.explanation?.contains("no cleanup classification") == true)
    }

    func testHiddenTopLevelFolderIsExcluded() async throws {
        let home = try UserHomeTestDirectory()
        let hidden = try makeFolder(named: ".private-project", fileSize: 8_192, in: home.url)

        let report = await makeAnalyzer(home: home.url).analyze()

        XCTAssertNil(storageNode(at: hidden.path, in: report.result.root))
        XCTAssertFalse(report.roots.contains { $0.node.absolutePath == hidden.path })
    }

    func testLibraryIsNotRecursivelyScanned() async throws {
        let home = try UserHomeTestDirectory()
        let library = home.url.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let payload = support.appendingPathComponent("large.dat")
        try Data(repeating: 0x31, count: 1_048_576).write(to: payload)
        _ = try makeFolder(named: "Documents", fileSize: 1_024, in: home.url)

        let report = await makeAnalyzer(home: home.url).analyze()

        XCTAssertNil(storageNode(at: library.path, in: report.result.root))
        XCTAssertNil(storageNode(at: payload.path, in: report.result.root))
        XCTAssertLessThan(report.combinedUniqueLogicalSize, 1_048_576)
    }

    func testSpecializedLibraryRootsAreExplicitlyExcluded() async throws {
        let home = try UserHomeTestDirectory()
        let report = await makeAnalyzer(home: home.url).analyze()
        let library = home.url.appendingPathComponent("Library", isDirectory: true)

        XCTAssertEqual(Set(report.excludedCanonicalPaths), Set([
            library.path,
            library.appendingPathComponent("Application Support").path,
            library.appendingPathComponent("Containers").path,
            library.appendingPathComponent("Group Containers").path,
        ]))
    }

    func testTopLevelRootsSortByAllocatedSizeDescending() async throws {
        let home = try UserHomeTestDirectory()
        _ = try makeFolder(named: "Small", fileSize: 4_096, in: home.url)
        _ = try makeFolder(named: "Large", fileSize: 1_048_576, in: home.url)
        _ = try makeFolder(named: "Medium", fileSize: 131_072, in: home.url)

        let report = await UserHomeStorageAnalyzer(
            homeDirectoryURL: home.url,
            largeAllocatedSizeThreshold: 1
        ).analyze()

        XCTAssertEqual(report.roots.map(\.node.name), ["Large", "Medium", "Small"])
        XCTAssertTrue(zip(report.roots, report.roots.dropFirst()).allSatisfy {
            $0.node.allocatedSize >= $1.node.allocatedSize
        })
        XCTAssertTrue(report.roots.allSatisfy { $0.node.metadata.isUnusuallyLarge == true })
    }

    func testCompleteHierarchyIsPreserved() async throws {
        let home = try UserHomeTestDirectory()
        let documents = home.url.appendingPathComponent("Documents", isDirectory: true)
        let project = documents.appendingPathComponent("Project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try Data(repeating: 0x42, count: 2_048).write(to: file)

        let report = await makeAnalyzer(home: home.url).analyze()

        XCTAssertNotNil(storageNode(at: documents.path, in: report.result.root))
        XCTAssertNotNil(storageNode(at: project.path, in: report.result.root))
        XCTAssertNotNil(storageNode(at: nested.path, in: report.result.root))
        XCTAssertEqual(storageNode(at: file.path, in: report.result.root)?.ownLogicalSize, 2_048)
    }

    func testHiddenDescendantsWithinVisibleFolderAreIncluded() async throws {
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let hidden = documents.appendingPathComponent(".project-state")
        try Data(repeating: 0x43, count: 1_024).write(to: hidden)

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: hidden.path, in: report.result.root))

        XCTAssertTrue(node.isHidden)
        XCTAssertEqual(node.ownLogicalSize, 1_024)
    }

    func testLogicalAndAllocatedSizesMatchFilesystemMetadata() async throws {
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let file = documents.appendingPathComponent("data.bin")
        try Data(repeating: 0x44, count: 70_000).write(to: file)
        let expected = try userHomeStatValues(for: file.path)

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: file.path, in: report.result.root))

        XCTAssertEqual(node.ownLogicalSize, expected.logical)
        XCTAssertEqual(node.ownAllocatedSize, expected.allocated)
    }

    func testSparseFilePreservesLogicalAndAllocatedDistinction() async throws {
        let home = try UserHomeTestDirectory()
        let movies = try makeFolder(named: "Movies", fileSize: 0, in: home.url)
        let disk = movies.appendingPathComponent("virtual-machine.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024)
        try handle.close()

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: disk.path, in: report.result.root))

        XCTAssertEqual(node.ownLogicalSize, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(node.ownAllocatedSize, node.ownLogicalSize)
        if node.ownAllocatedSize >= node.ownLogicalSize {
            throw XCTSkip("The test filesystem eagerly allocated the sparse file.")
        }
    }

    func testSymbolicLinkIsVisibleButTargetIsNotTraversed() async throws {
        let home = try UserHomeTestDirectory()
        let outside = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let target = try makeFolder(named: "Target", fileSize: 1_048_576, in: outside.url)
        let link = documents.appendingPathComponent("External")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: link.path, in: report.result.root))

        XCTAssertTrue(node.isSymbolicLink)
        XCTAssertEqual(node.itemType, .symbolicLink)
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertNil(storageNode(at: target.appendingPathComponent("payload.dat").path, in: report.result.root))
    }

    func testHardLinksAcrossVisibleRootsAreCountedOnce() async throws {
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let downloads = try makeFolder(named: "Downloads", fileSize: 0, in: home.url)
        let original = documents.appendingPathComponent("shared.dat")
        let link = downloads.appendingPathComponent("shared.dat")
        try Data(repeating: 0x45, count: 16_384).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)

        let report = await makeAnalyzer(home: home.url).analyze()
        let nodes = [
            try XCTUnwrap(storageNode(at: original.path, in: report.result.root)),
            try XCTUnwrap(storageNode(at: link.path, in: report.result.root)),
        ]

        XCTAssertEqual(nodes.filter(\.isCountedInParentTotals).count, 1)
        XCTAssertEqual(
            nodes.filter(\.isCountedInParentTotals).reduce(Int64(0)) { $0 + $1.ownAllocatedSize },
            nodes[0].ownAllocatedSize
        )
    }

    func testFilesystemBoundaryStateIsPreservedWithoutBytes() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        let issue = StorageScanIssue(
            path: "/Users/test/ExternalVolume",
            kind: .differentVolume,
            message: "Skipped mounted filesystem.",
            posixErrorCode: nil
        )
        let boundary = syntheticUserHomeNode(
            path: issue.path,
            itemType: .volumeBoundary,
            accessibility: .skippedDifferentVolume,
            issues: [issue],
            isCounted: false
        )
        let input = syntheticUserHomeResult(home: home, children: [boundary], issues: [issue])

        let report = UserHomeStorageAnalyzer.makeReport(
            input,
            homeDirectoryURL: home,
            largeAllocatedSizeThreshold: 1
        )
        let preserved = try XCTUnwrap(report.roots.first?.node)

        XCTAssertEqual(preserved.itemType, .volumeBoundary)
        XCTAssertEqual(preserved.accessibility, .skippedDifferentVolume)
        XCTAssertEqual(preserved.allocatedSize, 0)
        XCTAssertEqual(report.issues.first?.kind, .differentVolume)
    }

    func testPermissionDeniedFolderIsReported() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 directories.") }
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let protected = try makeFolder(named: "Protected", fileSize: 128, in: documents)
        XCTAssertEqual(chmod(protected.path, 0), 0)
        defer { _ = chmod(protected.path, mode_t(S_IRWXU)) }

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: protected.path, in: report.result.root))

        XCTAssertEqual(node.accessibility, .inaccessible)
        XCTAssertTrue(report.issues.contains {
            $0.path == protected.path && $0.kind == .permissionDenied
        })
    }

    func testCancellationReturnsPartialMarkedReport() async throws {
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        for index in 0..<300 {
            _ = try makeFolder(named: "Folder-\(index)", fileSize: 64, in: documents)
        }
        let analyzer = makeAnalyzer(
            home: home.url,
            scanner: FileTreeScanner(configuration: .init(maxConcurrentDirectoryReads: 1))
        )
        let task = Task { await analyzer.analyze() }
        task.cancel()

        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.issues.contains { $0.kind == .cancelled })
    }

    func testMissingOptionalStandardFoldersAreExplicit() async throws {
        let home = try UserHomeTestDirectory()
        _ = try makeFolder(named: "Documents", fileSize: 0, in: home.url)

        let report = await makeAnalyzer(home: home.url).analyze()

        XCTAssertEqual(status(.documents, in: report)?.state, .present)
        XCTAssertEqual(status(.downloads, in: report)?.state, .missing)
        XCTAssertEqual(status(.pictures, in: report)?.state, .missing)
    }

    func testEmptyHomeReturnsNoRootsAndZeroSelectedBytes() async throws {
        let home = try UserHomeTestDirectory()

        let report = await makeAnalyzer(home: home.url).analyze()

        XCTAssertTrue(report.roots.isEmpty)
        XCTAssertEqual(report.combinedUniqueLogicalSize, 0)
        XCTAssertEqual(report.combinedUniqueAllocatedSize, 0)
        XCTAssertTrue(report.standardDirectories.allSatisfy { $0.state == .missing })
    }

    func testSyntheticCloudPlaceholderUsesAllocatedBytesAsLocalConsumption() async throws {
        let home = try UserHomeTestDirectory()
        let cloud = try makeFolder(named: "Cloud Projects", fileSize: 0, in: home.url)
        let placeholder = cloud.appendingPathComponent("remote-video.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: placeholder.path, contents: nil))
        let handle = try FileHandle(forWritingTo: placeholder)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()

        let report = await makeAnalyzer(home: home.url).analyze()
        let node = try XCTUnwrap(storageNode(at: placeholder.path, in: report.result.root))

        XCTAssertEqual(node.ownLogicalSize, 64 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(node.ownAllocatedSize, node.ownLogicalSize)
        XCTAssertEqual(
            report.result.root.metadata.attributes[UserHomeStorageAnalyzer.MetadataKey.localDiskAccounting],
            "allocated-size-only"
        )
    }

    func testAnalysisDoesNotMutateFiles() async throws {
        let home = try UserHomeTestDirectory()
        let documents = try makeFolder(named: "Documents", fileSize: 0, in: home.url)
        let file = documents.appendingPathComponent("important.txt")
        let original = Data("do not change".utf8)
        try original.write(to: file)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: file.path)

        _ = await makeAnalyzer(home: home.url).analyze()

        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(
            attributesBefore[.size] as? NSNumber,
            try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        )
    }

    private func assertStandardDirectory(_ directory: UserHomeStandardDirectory) async throws {
        let home = try UserHomeTestDirectory()
        let folder = try makeFolder(named: directory.rawValue, fileSize: 1_024, in: home.url)

        let report = await makeAnalyzer(home: home.url).analyze()
        let root = try XCTUnwrap(report.roots.first { $0.node.absolutePath == folder.path })

        XCTAssertEqual(root.standardDirectory, directory)
        XCTAssertEqual(status(directory, in: report)?.state, .present)
        XCTAssertGreaterThanOrEqual(root.node.logicalSize, 1_024)
    }
}

private final class UserHomeTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-UserHomeStorageAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeAnalyzer(
    home: URL,
    scanner: FileTreeScanner = FileTreeScanner()
) -> UserHomeStorageAnalyzer {
    UserHomeStorageAnalyzer(homeDirectoryURL: home, scanner: scanner)
}

@discardableResult
private func makeFolder(named name: String, fileSize: Int, in root: URL) throws -> URL {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    if fileSize > 0 {
        try Data(repeating: UInt8(fileSize % 251), count: fileSize).write(
            to: folder.appendingPathComponent("payload.dat")
        )
    }
    return folder
}

private func status(
    _ directory: UserHomeStandardDirectory,
    in report: UserHomeStorageReport
) -> UserHomeStandardDirectoryStatus? {
    report.standardDirectories.first { $0.directory == directory }
}

private func storageNode(at path: String, in root: StorageNode) -> StorageNode? {
    var pending = [root]
    while let candidate = pending.popLast() {
        if candidate.absolutePath == path { return candidate }
        pending.append(contentsOf: candidate.children)
    }
    return nil
}

private func userHomeStatValues(for path: String) throws -> (logical: Int64, allocated: Int64) {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }
    return (Int64(metadata.st_size), Int64(metadata.st_blocks) * 512)
}

private func syntheticUserHomeNode(
    path: String,
    itemType: StorageItemType = .directory,
    accessibility: StorageAccessibility = .accessible,
    issues: [StorageScanIssue] = [],
    children: [StorageNode] = [],
    isCounted: Bool = true
) -> StorageNode {
    StorageNode(
        name: URL(fileURLWithPath: path).lastPathComponent,
        absolutePath: path,
        logicalSize: 0,
        allocatedSize: 0,
        ownLogicalSize: 0,
        ownAllocatedSize: 0,
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

private func syntheticUserHomeResult(
    home: URL,
    children: [StorageNode],
    issues: [StorageScanIssue]
) -> StorageAnalysisResult {
    let date = Date(timeIntervalSince1970: 1)
    return StorageAnalysisResult(
        root: syntheticUserHomeNode(path: home.path, children: children, isCounted: false),
        startedAt: date,
        completedAt: date,
        rootDeviceIdentifier: 1,
        wasCancelled: false,
        issues: issues
    )
}
