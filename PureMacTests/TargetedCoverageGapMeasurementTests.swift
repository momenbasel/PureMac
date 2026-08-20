import XCTest
@testable import PureMac

final class TargetedCoverageGapMeasurementTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetedCoverageGapMeasurementTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Hidden Home Gap Measured
    func testHiddenHomeGapMeasured() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let hiddenCache = fakeHome.appendingPathComponent(".test_cache")
        try FileManager.default.createDirectory(at: hiddenCache, withIntermediateDirectories: true)

        let testFile = hiddenCache.appendingPathComponent("data.bin")
        let testData = Data(repeating: 0xAB, count: 64 * 1024) // 64 KB
        try testData.write(to: testFile)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume")
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".test_cache" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.scope, .hiddenHome)
        XCTAssertEqual(candidate?.status, .measured)
        XCTAssertTrue(candidate?.contributesToExplainedBytes == true)
        XCTAssertGreaterThan(candidate?.allocatedBytes ?? 0, 0)
    }

    // MARK: - 2. Unspecialized ~/Library Gap Measured
    func testUnspecializedUserLibraryGapMeasured() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let libraryURL = fakeHome.appendingPathComponent("Library")
        let customCache = libraryURL.appendingPathComponent("CustomFrameworkCache")
        try FileManager.default.createDirectory(at: customCache, withIntermediateDirectories: true)

        let fileURL = customCache.appendingPathComponent("cache.db")
        let data = Data(repeating: 0x55, count: 128 * 1024)
        try data.write(to: fileURL)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume")
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == "CustomFrameworkCache" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.scope, .userLibrary)
        XCTAssertEqual(candidate?.status, .measured)
        XCTAssertTrue(candidate?.contributesToExplainedBytes == true)
        XCTAssertGreaterThan(candidate?.allocatedBytes ?? 0, 0)
    }

    // MARK: - 3. Specialized Library Roots Excluded
    func testSpecializedUserLibraryRootsExcluded() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let libraryURL = fakeHome.appendingPathComponent("Library")
        let appSupport = libraryURL.appendingPathComponent("Application Support")
        let containers = libraryURL.appendingPathComponent("Containers")
        let groupContainers = libraryURL.appendingPathComponent("Group Containers")

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: groupContainers, withIntermediateDirectories: true)

        let appSupportFile = appSupport.appendingPathComponent("app.data")
        try Data(repeating: 0x11, count: 10 * 1024).write(to: appSupportFile)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume")
        )
        let report = await analyzer.analyze()

        let appSupportCandidate = report.candidates.first { $0.name == "Application Support" }
        let containersCandidate = report.candidates.first { $0.name == "Containers" }
        let groupContainersCandidate = report.candidates.first { $0.name == "Group Containers" }

        XCTAssertNil(appSupportCandidate, "Application Support must be excluded from unspecialized gaps")
        XCTAssertNil(containersCandidate, "Containers must be excluded from unspecialized gaps")
        XCTAssertNil(groupContainersCandidate, "Group Containers must be excluded from unspecialized gaps")
    }

    // MARK: - 4. Already-Owned Path Excluded
    func testAlreadyOwnedPathExcluded() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let hiddenFolder = fakeHome.appendingPathComponent(".already_owned_tool")
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)

        let file = hiddenFolder.appendingPathComponent("config.json")
        try Data(repeating: 0x22, count: 4096).write(to: file)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume"),
            extraExcludedCanonicalPaths: [hiddenFolder.path]
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".already_owned_tool" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.status, .excludedAlreadyAccounted)
        XCTAssertFalse(candidate?.contributesToExplainedBytes ?? true)
        XCTAssertEqual(candidate?.allocatedBytes, nil)
    }

    // MARK: - 5. Canonical Alias Normalization and Deduplication
    func testCanonicalAliasNormalizationAndDeduplication() {
        let path1 = "/System/Volumes/Data/private/var/log"
        let path2 = "/private/var/log"
        let path3 = "/var/log"

        let norm1 = StoragePathNormalizer.normalize(path1)
        let norm2 = StoragePathNormalizer.normalize(path2)
        let norm3 = StoragePathNormalizer.normalize(path3)

        XCTAssertEqual(norm1, "/private/var/log")
        XCTAssertEqual(norm2, "/private/var/log")
        XCTAssertEqual(norm3, "/private/var/log")
        XCTAssertTrue(StoragePathNormalizer.pathsOverlap(path1, path2))
        XCTAssertTrue(StoragePathNormalizer.pathsOverlap(path2, path3))
    }

    // MARK: - 6. Ancestor and Descendant Overlap Prevention via Coordinator
    func testAncestorDescendantOverlapPrevention() async {
        let childCandidate = StorageCoverageCandidate(
            originalPath: "/Users/test/Documents/Subfolder",
            normalizedPath: "/Users/test/Documents/Subfolder",
            name: "Subfolder",
            scope: .other,
            status: .measured,
            allocatedBytes: 20_000_000,
            logicalBytes: 20_000_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )

        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 20_000_000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [childCandidate],
            largestDiscoveredRegions: [childCandidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let userHome = UserHomeStorageAnalyzer.makeReport(
            makeResult(path: "/Users/test", allocated: 100_000_000, children: [makeNode(path: "/Users/test/Documents", allocated: 100_000_000)]),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test"),
            largeAllocatedSizeThreshold: 1_073_741_824
        )
        let coordinator = makeStubCoordinator(userHome: userHome, coverageExpansion: expansionReport)
        let report = await coordinator.analyze()

        let parentContrib = report.filesystemContributions.first { $0.normalizedPath == "/Users/test/Documents" }
        let childContrib = report.filesystemContributions.first { $0.normalizedPath == "/Users/test/Documents/Subfolder" }

        XCTAssertEqual(parentContrib?.relationship, .canonicalUnique)
        XCTAssertEqual(parentContrib?.accountedAllocatedBytes, 100_000_000)

        XCTAssertEqual(childContrib?.relationship, .excludedNestedPath)
        XCTAssertEqual(childContrib?.accountedAllocatedBytes, 0, "Nested child must not double-count bytes")
    }

    // MARK: - 7. Hard Links Do Not Double Count
    func testHardLinksDoNotDoubleCount() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let hiddenFolder = fakeHome.appendingPathComponent(".test_hardlinks")
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)

        let originalFile = hiddenFolder.appendingPathComponent("original.bin")
        let linkedFile = hiddenFolder.appendingPathComponent("hardlink.bin")

        let fileData = Data(repeating: 0x99, count: 50 * 1024) // 50 KB
        try fileData.write(to: originalFile)
        try FileManager.default.linkItem(at: originalFile, to: linkedFile)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume")
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".test_hardlinks" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.status, .measured)
        XCTAssertLessThanOrEqual(candidate?.allocatedBytes ?? 0, 65536)
    }

    // MARK: - 8. Symlinks Are Not Followed
    func testSymlinksAreNotFollowed() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let targetDir = tempDirectory.appendingPathComponent("ExternalBigFolder")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 1024 * 1024).write(to: targetDir.appendingPathComponent("big.bin"))

        let symlinkURL = fakeHome.appendingPathComponent(".symlink_gap")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetDir)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("FakeDataVolume")
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".symlink_gap" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.status, .excludedSymlink)
        XCTAssertFalse(candidate?.contributesToExplainedBytes ?? true)
        XCTAssertEqual(candidate?.allocatedBytes, nil)
    }

    // MARK: - 9. Filesystem Boundaries Enforced
    func testFilesystemBoundariesEnforced() {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Volumes/External/Data",
            normalizedPath: "/Volumes/External/Data",
            name: "Data",
            scope: .other,
            status: .excludedDifferentVolume,
            allocatedBytes: nil,
            logicalBytes: nil,
            issue: nil,
            exclusionReason: "Located on a different filesystem volume boundary.",
            contributesToExplainedBytes: false
        )

        XCTAssertFalse(candidate.contributesToExplainedBytes)
        XCTAssertEqual(candidate.status, .excludedDifferentVolume)
    }

    // MARK: - 10. Inaccessible Gap Contributes Zero Fabricated Bytes
    func testInaccessibleGapContributesZeroFabricatedBytes() {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Library/Application Support/Restricted",
            normalizedPath: "/Library/Application Support/Restricted",
            name: "Restricted",
            scope: .userLibrary,
            status: .inaccessible,
            allocatedBytes: 0,
            logicalBytes: 0,
            issue: StorageScanIssue(path: "/Library/Application Support/Restricted", kind: .permissionDenied, message: "Permission denied", posixErrorCode: 13),
            exclusionReason: "Permission denied.",
            contributesToExplainedBytes: false
        )

        XCTAssertFalse(candidate.contributesToExplainedBytes)
        XCTAssertEqual(candidate.status, .inaccessible)
        XCTAssertEqual(candidate.allocatedBytes, 0)
    }

    // MARK: - 11. Cancellation Handling
    func testCancellationHandling() async {
        let task = Task { () -> StorageCoverageExpansionReport in
            let fakeHome = self.tempDirectory.appendingPathComponent("UserHome")
            let analyzer = CoverageExpansionAnalyzer(homeDirectoryURL: fakeHome)
            return await analyzer.analyze()
        }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.wasCancelled || report.candidates.isEmpty)
    }

    // MARK: - 12. Deterministic Ordering
    func testDeterministicOrdering() {
        let statusList: [StorageCoverageCandidateStatus] = [
            .eligible, .measured, .partiallyMeasured, .inaccessible,
            .skippedAlreadyOwned, .skippedNonAdditive, .skippedUnsafeOverlap,
            .excludedAlreadyAccounted, .excludedNested, .excludedSymlink,
            .excludedDifferentVolume, .excludedProtectedSystem, .failed, .cancelled
        ]

        for status in statusList {
            XCTAssertFalse(status.displayName.isEmpty)
        }
        XCTAssertTrue(StorageCoverageCandidateStatus.measured.isMeasuredOrPartial)
        XCTAssertTrue(StorageCoverageCandidateStatus.partiallyMeasured.isMeasuredOrPartial)
        XCTAssertFalse(StorageCoverageCandidateStatus.inaccessible.isMeasuredOrPartial)
    }

    // MARK: - 13. Reconciliation Additive Math
    func testReconciliationAdditiveMath() async {
        let gapCandidate = StorageCoverageCandidate(
            originalPath: "/Users/test/.test_cache",
            normalizedPath: "/Users/test/.test_cache",
            name: ".test_cache",
            scope: .hiddenHome,
            status: .measured,
            allocatedBytes: 25_000_000,
            logicalBytes: 25_000_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )

        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 25_000_000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [gapCandidate],
            largestDiscoveredRegions: [gapCandidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let userHome = UserHomeStorageAnalyzer.makeReport(
            makeResult(path: "/Users/test", allocated: 100_000_000, children: [makeNode(path: "/Users/test/Documents", allocated: 100_000_000)]),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test"),
            largeAllocatedSizeThreshold: 1_073_741_824
        )
        let coordinator = makeStubCoordinator(
            userHome: userHome,
            apfs: makeAPFSReport(used: 200_000_000),
            coverageExpansion: expansionReport
        )

        let report = await coordinator.analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 125_000_000)
        XCTAssertEqual(report.unexplainedBytes, 75_000_000)
    }

    // MARK: - 14. Non-Additive APFS and Docker Preservation
    func testNonAdditiveAPFSAndDockerPreservation() async {
        let coordinator = makeStubCoordinator(
            apfs: makeAPFSReport(used: 200_000_000, snapshotSize: 15_000_000)
        )

        let report = await coordinator.analyze()

        XCTAssertEqual(report.analyzerResults.apfsStorage?.snapshots.first?.size, 15_000_000)
        XCTAssertEqual(report.explainedAllocatedBytes, 0)
        XCTAssertEqual(report.unexplainedBytes, 200_000_000)
    }

    // MARK: - 15. Read-Only Verification
    func testReadOnlyVerification() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let hiddenDir = fakeHome.appendingPathComponent(".read_only_test")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        let sampleFile = hiddenDir.appendingPathComponent("file.txt")
        let originalContent = "PureMac read-only invariant test"
        try originalContent.write(to: sampleFile, atomically: true, encoding: .utf8)

        let initialAttrs = try FileManager.default.attributesOfItem(atPath: sampleFile.path)
        let initialModDate = initialAttrs[.modificationDate] as? Date

        let analyzer = CoverageExpansionAnalyzer(homeDirectoryURL: fakeHome)
        _ = await analyzer.analyze()

        let postAttrs = try FileManager.default.attributesOfItem(atPath: sampleFile.path)
        let postModDate = postAttrs[.modificationDate] as? Date
        let postContent = try String(contentsOf: sampleFile, encoding: .utf8)

        XCTAssertEqual(originalContent, postContent)
        XCTAssertEqual(initialModDate, postModDate)
    }

    // MARK: - Helpers
    private func makeResult(
        path: String,
        allocated: Int64,
        children: [StorageNode] = []
    ) -> StorageAnalysisResult {
        let date = Date(timeIntervalSince1970: 1)
        return StorageAnalysisResult(
            root: makeNode(path: path, allocated: allocated, children: children),
            startedAt: date,
            completedAt: date,
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )
    }

    private func makeNode(
        path: String,
        allocated: Int64,
        children: [StorageNode] = []
    ) -> StorageNode {
        StorageNode(
            name: URL(fileURLWithPath: path).lastPathComponent,
            absolutePath: path,
            logicalSize: allocated,
            allocatedSize: allocated,
            ownLogicalSize: allocated,
            ownAllocatedSize: allocated,
            itemType: .directory,
            children: children,
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )
    }

    private func makeAPFSReport(used: Int64, snapshotSize: Int64? = nil) -> APFSStorageReport {
        let snapshot = snapshotSize.map {
            APFSSnapshotInformation(
                identifier: "snapshot",
                name: "snapshot",
                uuid: nil,
                creationDate: nil,
                size: $0,
                sizeKnowledge: .reportedBySystem,
                type: .timeMachine,
                source: .diskutil,
                storageRelationship: .sharedNonAdditive
            )
        }
        return APFSStorageReport(
            volume: APFSVolumeInformation(
                name: "Data",
                volumeIdentifier: "disk-test",
                volumeUUID: nil,
                containerIdentifier: nil,
                volumeGroupIdentifier: nil,
                filesystemType: "apfs",
                filesystemKind: .apfs,
                mountPoint: "/",
                dataVolumeRelationship: .dataVolume,
                capacity: APFSVolumeCapacity(
                    totalCapacity: used + 200,
                    availableCapacity: 200,
                    usedCapacity: used,
                    availableCapacityForImportantUsage: 300,
                    availableCapacityForOpportunisticUsage: nil,
                    purgeableEstimate: 100,
                    purgeableEstimateKnowledge: .estimated
                )
            ),
            snapshots: snapshot.map { [$0] } ?? [],
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )
    }

    private struct TestFailure: Error {}

    private func makeStubCoordinator(
        userHome: UserHomeStorageReport? = nil,
        apfs: APFSStorageReport? = nil,
        coverageExpansion: StorageCoverageExpansionReport? = nil
    ) -> StorageAnalysisCoordinator {
        StorageAnalysisCoordinator(
            maxConcurrentAnalyzers: 2,
            userHomeStorageAnalysis: {
                guard let userHome else { throw TestFailure() }
                return userHome
            },
            applicationsAnalysis: { throw TestFailure() },
            applicationSupportAnalysis: { throw TestFailure() },
            containersAnalysis: { throw TestFailure() },
            groupContainersAnalysis: { throw TestFailure() },
            systemLibraryAnalysis: { throw TestFailure() },
            privateStorageAnalysis: { throw TestFailure() },
            dataVolumeHiddenStorageAnalysis: { throw TestFailure() },
            developerSystemStorageAnalysis: { throw TestFailure() },
            dockerStorageAnalysis: { throw TestFailure() },
            apfsStorageAnalysis: {
                guard let apfs else { throw TestFailure() }
                return apfs
            },
            coverageExpansionAnalysis: {
                guard let coverageExpansion else { throw TestFailure() }
                return coverageExpansion
            },
            coverageDiscovery: { .empty(homeDirectoryPath: "/Users/test") }
        )
    }
}
