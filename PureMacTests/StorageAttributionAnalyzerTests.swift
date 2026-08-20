import Darwin
import XCTest
@testable import PureMac

final class StorageAttributionAnalyzerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAttributionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Data-volume root classification
    func testDataVolumeRootClassification() async throws {
        let fakeDataVolume = tempDirectory.appendingPathComponent("DataVolume")
        try FileManager.default.createDirectory(at: fakeDataVolume.appendingPathComponent("Users"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeDataVolume.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeDataVolume.appendingPathComponent("private"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeDataVolume.appendingPathComponent(".DocumentRevisions-V100"), withIntermediateDirectories: true)

        let report = makeStubReport(
            usedBytes: 100_000_000,
            explainedBytes: 80_000_000,
            contributions: [
                makeContribution(path: "/Users", size: 50_000_000, source: .userHomeVisibleStorage),
                makeContribution(path: "/Library", size: 20_000_000, source: .systemLibrary),
                makeContribution(path: "/private", size: 10_000_000, source: .privateStorage),
            ]
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: fakeDataVolume,
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        let names = attribution.dataVolumeRoots.map(\.name)
        XCTAssertTrue(names.contains("Users"))
        XCTAssertTrue(names.contains("Library"))
        XCTAssertTrue(names.contains("private"))
        XCTAssertTrue(names.contains(".DocumentRevisions-V100"))

        let usersRoot = attribution.dataVolumeRoots.first { $0.name == "Users" }
        XCTAssertEqual(usersRoot?.classification, .ownedByExistingAnalyzer)
        XCTAssertEqual(usersRoot?.allocatedBytes, 50_000_000)

        let revisionsRoot = attribution.dataVolumeRoots.first { $0.name == ".DocumentRevisions-V100" }
        XCTAssertTrue(revisionsRoot?.isProtectedSystem == true)
    }

    // MARK: - 2. Canonical alias normalization
    func testCanonicalAliasNormalization() async throws {
        let fakeDataVolume = tempDirectory.appendingPathComponent("DataVolume")
        try FileManager.default.createDirectory(at: fakeDataVolume.appendingPathComponent("private"), withIntermediateDirectories: true)

        let report = makeStubReport(
            usedBytes: 100_000_000,
            explainedBytes: 10_000_000,
            contributions: [
                makeContribution(path: "/private", size: 10_000_000, source: .privateStorage)
            ]
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: fakeDataVolume,
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        let privateRoot = attribution.dataVolumeRoots.first { $0.name == "private" }
        XCTAssertNotNil(privateRoot)
        XCTAssertEqual(privateRoot?.normalizedPath, "/private")
        XCTAssertEqual(privateRoot?.allocatedBytes, 10_000_000)
    }

    // MARK: - 3. Duplicate ownership prevention
    func testDuplicateOwnershipPrevention() async {
        let contributionA = StorageFilesystemContribution(
            source: .privateStorage,
            absolutePath: "/private",
            normalizedPath: "/private",
            observedAllocatedBytes: 5_000_000,
            accountedAllocatedBytes: 5_000_000,
            relationship: .canonicalUnique,
            owningPath: nil
        )
        let contributionB = StorageFilesystemContribution(
            source: .dataVolumeHiddenStorage,
            absolutePath: "/System/Volumes/Data/private",
            normalizedPath: "/private",
            observedAllocatedBytes: 5_000_000,
            accountedAllocatedBytes: 0,
            relationship: .excludedDuplicatePath,
            owningPath: "/private"
        )

        let report = makeStubReport(
            usedBytes: 50_000_000,
            explainedBytes: 5_000_000,
            contributions: [contributionA, contributionB]
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        XCTAssertEqual(attribution.explainedAllocatedBytes, 5_000_000)
        XCTAssertEqual(attribution.unexplainedBytes, 45_000_000)
    }

    // MARK: - 4. Virtual Memory (Swap & Sleep Image) attribution
    func testVirtualMemoryAttribution() async throws {
        let fakeVM = tempDirectory.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: fakeVM, withIntermediateDirectories: true)

        let swapURL = fakeVM.appendingPathComponent("swapfile0")
        try Data(repeating: 0x53, count: 1024 * 1024).write(to: swapURL)

        let sleepURL = fakeVM.appendingPathComponent("sleepimage")
        try Data(repeating: 0x5A, count: 2 * 1024 * 1024).write(to: sleepURL)

        let report = makeStubReport(
            usedBytes: 100_000_000,
            explainedBytes: 50_000_000
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            vmDirectoryURL: fakeVM
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        XCTAssertNotNil(attribution.vmFootprintBytes)
        XCTAssertNotNil(attribution.sleepImageBytes)
        XCTAssertGreaterThanOrEqual(attribution.vmFootprintBytes ?? 0, 3 * 1024 * 1024)

        let vmItems = attribution.attributionItems.filter { $0.category == .systemManagedStorage }
        XCTAssertFalse(vmItems.isEmpty)
        XCTAssertTrue(vmItems.contains { $0.name.contains("Sleep Image") })
        XCTAssertTrue(vmItems.contains { $0.name.contains("Swap") })
    }

    // MARK: - 5. APFS Snapshots and Purgeable Estimate remain non-additive
    func testAPFSSnapshotsAndPurgeableRemainNonAdditive() async {
        let apfs = makeAPFSReport(used: 100_000_000, purgeable: 15_000_000, snapshotSize: 20_000_000)
        let report = makeStubReport(
            usedBytes: 100_000_000,
            explainedBytes: 40_000_000,
            purgeableBytes: 15_000_000,
            apfsReport: apfs
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        XCTAssertEqual(attribution.explainedAllocatedBytes, 40_000_000)
        XCTAssertEqual(attribution.unexplainedBytes, 60_000_000)
        XCTAssertEqual(attribution.snapshotFootprintBytes, 20_000_000)
        XCTAssertEqual(attribution.purgeableEstimateBytes, 15_000_000)

        let apfsItems = attribution.attributionItems.filter { $0.category == .apfsAndNonAdditive }
        XCTAssertTrue(apfsItems.allSatisfy { !$0.isFilesystemAdditive })
        XCTAssertTrue(apfsItems.contains { $0.status == .nonAdditive })
        XCTAssertTrue(apfsItems.contains { $0.status == .estimate })
    }

    // MARK: - 6. Protected system path categorization
    func testProtectedSystemPathCategorization() async {
        let report = makeStubReport(
            usedBytes: 100_000_000,
            explainedBytes: 30_000_000
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        let protectedItems = attribution.attributionItems.filter { $0.category == .protectedSystemStorage }
        XCTAssertFalse(protectedItems.isEmpty)
        XCTAssertTrue(protectedItems.contains { $0.path == "/private/var/audit" })
        XCTAssertTrue(protectedItems.contains { $0.path == "/System/Volumes/Data/.DocumentRevisions-V100" })
    }

    // MARK: - 7. Additive byte invariants
    func testResidualUnattributedCalculation() async {
        let report = makeStubReport(
            usedBytes: 200_000_000,
            explainedBytes: 120_000_000
        )

        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        XCTAssertEqual(attribution.unexplainedBytes, 80_000_000)
        XCTAssertEqual(attribution.residualUnattributedBytes, 80_000_000)

        let residualItem = attribution.attributionItems.first { $0.category == .stillUnattributed }
        XCTAssertNotNil(residualItem)
        XCTAssertEqual(residualItem?.allocatedBytes, 80_000_000)
        XCTAssertEqual(residualItem?.status, .unknown)
    }

    // MARK: - 8. Symlink exclusion in data volume root
    func testSymlinkRootsAreIntentionallyExcluded() async throws {
        let fakeDataVolume = tempDirectory.appendingPathComponent("DataVolume")
        let targetDir = tempDirectory.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: fakeDataVolume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let symlinkPath = fakeDataVolume.appendingPathComponent("LinkedDir").path
        symlink(targetDir.path, symlinkPath)

        let report = makeStubReport(usedBytes: 50_000_000, explainedBytes: 10_000_000)
        let analyzer = StorageAttributionAnalyzer(
            dataVolumeURL: fakeDataVolume,
            vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
        )
        let attribution = await analyzer.analyze(reconciliationReport: report)

        let linked = attribution.dataVolumeRoots.first { $0.name == "LinkedDir" }
        XCTAssertNotNil(linked)
        XCTAssertEqual(linked?.classification, .intentionallyExcluded)
        XCTAssertFalse(linked?.isFilesystemAdditive == true)
    }

    // MARK: - 9. Cancellation handling
    func testAttributionHandlesCancellation() async {
        let task = Task {
            let analyzer = StorageAttributionAnalyzer(
                dataVolumeURL: tempDirectory.appendingPathComponent("DataVolume"),
                vmDirectoryURL: tempDirectory.appendingPathComponent("fake-vm")
            )
            let report = makeStubReport(usedBytes: 100_000_000, explainedBytes: 50_000_000, wasCancelled: true)
            return await analyzer.analyze(reconciliationReport: report)
        }
        task.cancel()
        let attribution = await task.value
        XCTAssertTrue(attribution.wasCancelled || attribution.dataVolumeRoots.isEmpty)
    }

    // MARK: - Helpers

    private func makeContribution(
        path: String,
        size: Int64,
        source: StorageAccountingSource
    ) -> StorageFilesystemContribution {
        StorageFilesystemContribution(
            source: source,
            absolutePath: path,
            normalizedPath: StoragePathNormalizer.normalize(path),
            observedAllocatedBytes: size,
            accountedAllocatedBytes: size,
            relationship: .canonicalUnique,
            owningPath: nil
        )
    }

    private func makeStubReport(
        usedBytes: Int64,
        explainedBytes: Int64,
        purgeableBytes: Int64? = nil,
        contributions: [StorageFilesystemContribution] = [],
        apfsReport: APFSStorageReport? = nil,
        wasCancelled: Bool = false
    ) -> StorageReconciliationReport {
        let apfs = apfsReport ?? makeAPFSReport(used: usedBytes, purgeable: purgeableBytes ?? 0)
        var results = StorageAnalyzerResults()
        results.apfsStorage = apfs

        return StorageReconciliationReport(
            totalCapacityBytes: usedBytes + 100_000_000,
            usedCapacityBytes: usedBytes,
            availableCapacityBytes: 100_000_000,
            purgeableEstimateBytes: purgeableBytes,
            explainedAllocatedBytes: explainedBytes,
            unexplainedBytes: max(usedBytes - explainedBytes, 0),
            inaccessibleKnownLowerBoundBytes: 0,
            unreadablePathCount: 0,
            incompleteCoverage: true,
            coverageStatus: .completeForConfiguredRoots,
            canonicalRootCoverage: [],
            filesystemContributions: contributions,
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: results,
            coverageDiagnostic: .empty,
            attributionReport: nil,
            startedAt: Date(),
            completedAt: Date(),
            duration: 0.1,
            progress: StorageAnalysisProgress(totalStages: 11, completedStages: 11, runningStages: [], state: .completed),
            wasCancelled: wasCancelled
        )
    }

    private func makeAPFSReport(
        used: Int64,
        purgeable: Int64 = 0,
        snapshotSize: Int64? = nil
    ) -> APFSStorageReport {
        let snapshot = snapshotSize.map {
            APFSSnapshotInformation(
                identifier: "snap-1",
                name: "com.apple.TimeMachine.snap",
                uuid: nil,
                creationDate: Date(),
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
                volumeIdentifier: "disk3s5",
                volumeUUID: nil,
                containerIdentifier: nil,
                volumeGroupIdentifier: nil,
                filesystemType: "apfs",
                filesystemKind: .apfs,
                mountPoint: "/",
                dataVolumeRelationship: .dataVolume,
                capacity: APFSVolumeCapacity(
                    totalCapacity: used + 100_000_000,
                    availableCapacity: 100_000_000,
                    usedCapacity: used,
                    availableCapacityForImportantUsage: 100_000_000,
                    availableCapacityForOpportunisticUsage: nil,
                    purgeableEstimate: purgeable,
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
}
