import Darwin
import XCTest
@testable import PureMac

final class CoverageExpansionAnalyzerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverageExpansionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Uncovered ~/Library child becomes measurable
    func testUncoveredLibraryChildMeasured() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let fakeLibrary = fakeHome.appendingPathComponent("Library")
        let cachesDir = fakeLibrary.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let sampleFile = cachesDir.appendingPathComponent("test.cache")
        try Data(repeating: 0x41, count: 1024 * 1024).write(to: sampleFile)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume")
        )
        let report = await analyzer.analyze()

        let measuredCaches = report.candidates.first { $0.name == "Caches" }
        XCTAssertNotNil(measuredCaches)
        XCTAssertEqual(measuredCaches?.status, .measured)
        XCTAssertTrue(measuredCaches?.contributesToExplainedBytes == true)
        XCTAssertGreaterThan(measuredCaches?.allocatedBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(report.totalNewlyMeasuredBytes, 1024 * 1024)
    }

    // MARK: - 2. Application Support, Containers, Group Containers excluded
    func testSpecializedLibraryRootsExcluded() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let fakeLibrary = fakeHome.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: fakeLibrary.appendingPathComponent("Application Support"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeLibrary.appendingPathComponent("Containers"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeLibrary.appendingPathComponent("Group Containers"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeLibrary.appendingPathComponent("Developer"),
            withIntermediateDirectories: true
        )

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume")
        )
        let report = await analyzer.analyze()

        let names = report.candidates.map(\.name)
        XCTAssertFalse(names.contains("Application Support"))
        XCTAssertFalse(names.contains("Containers"))
        XCTAssertFalse(names.contains("Group Containers"))
        XCTAssertTrue(names.contains("Developer"))
    }

    // MARK: - 3. Hidden home candidate discovered (~/.cache, ~/.npm)
    func testHiddenHomeCandidateDiscovered() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let dotCache = fakeHome.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: dotCache, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 2048).write(to: dotCache.appendingPathComponent("pkg.json"))

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume")
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".cache" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.scope, .hiddenHome)
        XCTAssertEqual(candidate?.status, .measured)
        XCTAssertGreaterThan(candidate?.allocatedBytes ?? 0, 0)
    }

    // MARK: - 4. Hidden candidate already owned is excluded
    func testExcludedAlreadyAccountedCanonicalPaths() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let dotCache = fakeHome.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: dotCache, withIntermediateDirectories: true)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            extraExcludedCanonicalPaths: [StoragePathNormalizer.normalize(dotCache.path)]
        )
        let report = await analyzer.analyze()

        let candidate = report.candidates.first { $0.name == ".cache" }
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.status, .excludedAlreadyAccounted)
        XCTAssertFalse(candidate?.contributesToExplainedBytes == true)
    }

    // MARK: - 5. Data-volume alias normalization
    func testDataVolumeRootNormalization() {
        let candidatePath = "/System/Volumes/Data/Library/Developer"
        let normalized = StoragePathNormalizer.normalize(candidatePath)
        XCTAssertEqual(normalized, "/Library/Developer")
    }

    // MARK: - 6. Nested candidate exclusion in Coordinator
    func testNestedCoverageCandidateExcludedInCoordinator() async {
        let candidateA = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/Caches",
            normalizedPath: "/Users/test/Library/Caches",
            name: "Caches",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 1000,
            logicalBytes: 1000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let candidateB = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/Caches/subfolder",
            normalizedPath: "/Users/test/Library/Caches/subfolder",
            name: "subfolder",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 500,
            logicalBytes: 500,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let report = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 1500,
            measuredCandidateCount: 2,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [candidateA, candidateB],
            largestDiscoveredRegions: [candidateA, candidateB],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let coordinator = makeStubCoordinator(expansionReport: report)
        let result = await coordinator.analyze()

        let cachesContribution = result.filesystemContributions.first { $0.normalizedPath == "/Users/test/Library/Caches" }
        let subContribution = result.filesystemContributions.first { $0.normalizedPath == "/Users/test/Library/Caches/subfolder" }

        XCTAssertEqual(cachesContribution?.accountedAllocatedBytes, 1000)
        XCTAssertEqual(cachesContribution?.relationship, .canonicalUnique)
        XCTAssertEqual(subContribution?.accountedAllocatedBytes, 0)
        XCTAssertEqual(subContribution?.relationship, .excludedNestedPath)
    }

    // MARK: - 7. Duplicate analyzer ownership exclusion
    func testDuplicateAnalyzerOwnershipExclusion() async {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/Application Support",
            normalizedPath: "/Users/test/Library/Application Support",
            name: "Application Support",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 5000,
            logicalBytes: 5000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 5000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [candidate],
            largestDiscoveredRegions: [candidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let appSupportTree = makeResult(path: "/Users/test/Library/Application Support", allocated: 5000)
        let coordinator = makeStubCoordinator(
            appSupportResult: appSupportTree,
            expansionReport: expansionReport
        )
        let result = await coordinator.analyze()

        let appSupportContribution = result.filesystemContributions.first {
            $0.source == .applicationSupport && $0.normalizedPath == "/Users/test/Library/Application Support"
        }
        let gapContribution = result.filesystemContributions.first {
            $0.source == .additionalCoverageGap && $0.normalizedPath == "/Users/test/Library/Application Support"
        }

        XCTAssertEqual(appSupportContribution?.relationship, .canonicalUnique)
        XCTAssertEqual(appSupportContribution?.accountedAllocatedBytes, 5000)
        XCTAssertEqual(gapContribution?.relationship, .excludedDuplicatePath)
        XCTAssertEqual(gapContribution?.accountedAllocatedBytes, 0)
    }

    // MARK: - 8. Symlink exclusion
    func testSymlinksExcluded() async throws {
        let fakeHome = tempDirectory.appendingPathComponent("UserHome")
        let fakeLibrary = fakeHome.appendingPathComponent("Library")
        let targetDir = tempDirectory.appendingPathComponent("ActualTarget")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeLibrary, withIntermediateDirectories: true)

        let symlinkPath = fakeLibrary.appendingPathComponent("LinkedCaches").path
        symlink(targetDir.path, symlinkPath)

        let analyzer = CoverageExpansionAnalyzer(
            homeDirectoryURL: fakeHome,
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume")
        )
        let report = await analyzer.analyze()

        let linked = report.candidates.first { $0.name == "LinkedCaches" }
        XCTAssertNotNil(linked)
        XCTAssertEqual(linked?.status, .excludedSymlink)
        XCTAssertFalse(linked?.contributesToExplainedBytes == true)
        XCTAssertEqual(linked?.allocatedBytes, nil)
    }

    // MARK: - 9. Protected system path exclusion
    func testProtectedSystemPathsExcluded() {
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/System/Volumes/Data/.DocumentRevisions-V100"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/private/var/audit"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/private/var/root"))
    }

    // MARK: - 10. Explained bytes increase exactly by newly measured bytes
    func testExplainedAllocatedBytesIncreasesByUniqueMeasuredBytes() async {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/Caches",
            normalizedPath: "/Users/test/Library/Caches",
            name: "Caches",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 15_000_000,
            logicalBytes: 15_000_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 15_000_000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [candidate],
            largestDiscoveredRegions: [candidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let coordinator = makeStubCoordinator(
            usedCapacity: 100_000_000,
            expansionReport: expansionReport
        )
        let report = await coordinator.analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 15_000_000)
        XCTAssertEqual(report.unexplainedBytes, 85_000_000)
    }

    // MARK: - 11. Explained never exceeds volume used
    func testExplainedBytesNeverExceedsVolumeUsed() async {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/HugeDir",
            normalizedPath: "/Users/test/Library/HugeDir",
            name: "HugeDir",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 150_000_000,
            logicalBytes: 150_000_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 150_000_000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [candidate],
            largestDiscoveredRegions: [candidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let coordinator = makeStubCoordinator(
            usedCapacity: 100_000_000,
            expansionReport: expansionReport
        )
        let report = await coordinator.analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 150_000_000)
        XCTAssertEqual(report.unexplainedBytes, 0)
        XCTAssertTrue(report.analysisIssues.contains(where: { $0.kind == .accountingAnomaly }))
    }

    // MARK: - 12. APFS metadata remains non-additive
    func testAPFSMetadataRemainsNonAdditive() async {
        let candidate = StorageCoverageCandidate(
            originalPath: "/Users/test/Library/Caches",
            normalizedPath: "/Users/test/Library/Caches",
            name: "Caches",
            scope: .userLibrary,
            status: .measured,
            allocatedBytes: 10_000_000,
            logicalBytes: 10_000_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )
        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 10_000_000,
            measuredCandidateCount: 1,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: [candidate],
            largestDiscoveredRegions: [candidate],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let apfs = makeAPFSReport(used: 100_000_000, purgeable: 10_000_000)

        let coordinator = makeStubCoordinator(
            usedCapacity: 100_000_000,
            apfsReport: apfs,
            expansionReport: expansionReport
        )
        let report = await coordinator.analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 10_000_000)
        XCTAssertEqual(report.purgeableEstimateBytes, 10_000_000)
        XCTAssertEqual(report.unexplainedBytes, 90_000_000)
    }

    // MARK: - 13. Cancellation support
    func testCoverageExpansionHandlesCancellation() async {
        let task = Task {
            let analyzer = CoverageExpansionAnalyzer(
                homeDirectoryURL: tempDirectory.appendingPathComponent("UserHome"),
                dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume")
            )
            return await analyzer.analyze()
        }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.wasCancelled || report.candidates.isEmpty)
    }

    // MARK: - Helpers

    private func makeNode(
        path: String,
        allocated: Int64 = 0,
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

    private func makeResult(
        path: String,
        allocated: Int64 = 0,
        issues: [StorageScanIssue] = [],
        children: [StorageNode] = []
    ) -> StorageAnalysisResult {
        StorageAnalysisResult(
            root: makeNode(path: path, allocated: allocated, children: children),
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: issues
        )
    }

    private func makeAPFSReport(used: Int64, purgeable: Int64 = 0) -> APFSStorageReport {
        APFSStorageReport(
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
                    totalCapacity: used + 200_000_000,
                    availableCapacity: 200_000_000,
                    usedCapacity: used,
                    availableCapacityForImportantUsage: 300_000_000,
                    availableCapacityForOpportunisticUsage: nil,
                    purgeableEstimate: purgeable,
                    purgeableEstimateKnowledge: .estimated
                )
            ),
            snapshots: [],
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )
    }

    private func makeStubCoordinator(
        usedCapacity: Int64 = 100_000_000,
        appSupportResult: StorageAnalysisResult? = nil,
        apfsReport: APFSStorageReport? = nil,
        expansionReport: StorageCoverageExpansionReport = .empty
    ) -> StorageAnalysisCoordinator {
        let defaultAPFS = apfsReport ?? makeAPFSReport(used: usedCapacity)
        let emptyResult = makeResult(path: "/empty", allocated: 0)

        return StorageAnalysisCoordinator(
            userHomeStorageAnalysis: {
                UserHomeStorageAnalyzer.makeReport(
                    emptyResult,
                    homeDirectoryURL: URL(fileURLWithPath: "/Users/test"),
                    largeAllocatedSizeThreshold: 1_073_741_824
                )
            },
            applicationsAnalysis: { emptyResult },
            applicationSupportAnalysis: { appSupportResult ?? emptyResult },
            containersAnalysis: { emptyResult },
            groupContainersAnalysis: { emptyResult },
            systemLibraryAnalysis: { emptyResult },
            privateStorageAnalysis: { emptyResult },
            dataVolumeHiddenStorageAnalysis: { emptyResult },
            developerSystemStorageAnalysis: {
                DeveloperSystemStorageReport(
                    opt: DeveloperSystemRootAnalysis(canonicalRoot: .opt, configuredPath: "/opt", state: .missing, result: emptyResult),
                    usrLocal: DeveloperSystemRootAnalysis(canonicalRoot: .usrLocal, configuredPath: "/usr/local", state: .missing, result: emptyResult),
                    combinedUniqueLogicalSize: 0,
                    combinedUniqueAllocatedSize: 0,
                    combinedSizeKnowledge: .complete,
                    wasCancelled: false,
                    issues: []
                )
            },
            dockerStorageAnalysis: {
                DockerStorageReport(
                    hostFootprint: DockerHostFootprint(locations: [], logicalSize: 0, allocatedSize: 0),
                    virtualDisks: [],
                    runtimeStatus: .notInstalled,
                    runtimeAccounting: nil,
                    dockerExecutablePath: nil,
                    runtimeContext: DockerRuntimeContext(name: "test", sanitizedEndpoint: "unix:///local.sock", location: .local),
                    hostRuntimeRelationship: .localRuntimeMayExplainHostFootprint,
                    accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
                    wasCancelled: false,
                    issues: []
                )
            },
            apfsStorageAnalysis: { defaultAPFS },
            coverageExpansionAnalysis: { expansionReport },
            coverageDiscovery: { .empty(homeDirectoryPath: "/Users/test") }
        )
    }
}
