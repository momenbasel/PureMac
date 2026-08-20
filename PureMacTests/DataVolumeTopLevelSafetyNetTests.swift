import XCTest
@testable import PureMac

final class DataVolumeTopLevelSafetyNetTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacSafetyNetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func makeSyntheticReport(coverageExpansionCandidates: [StorageCoverageCandidate] = []) -> StorageReconciliationReport {
        let expansionReport = StorageCoverageExpansionReport(
            totalNewlyMeasuredBytes: 0,
            measuredCandidateCount: coverageExpansionCandidates.count,
            excludedOverlapCount: 0,
            inaccessibleCandidateCount: 0,
            differentVolumeBoundaryCount: 0,
            failedCandidateCount: 0,
            candidates: coverageExpansionCandidates,
            largestDiscoveredRegions: [],
            treeResults: [],
            wasCancelled: false,
            issues: []
        )

        let results = StorageAnalyzerResults(
            userHomeStorage: nil,
            applications: nil,
            applicationSupport: nil,
            containers: nil,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: nil,
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: nil,
            coverageExpansion: expansionReport,
            physicalReconciliation: nil
        )

        return StorageReconciliationReport(
            totalCapacityBytes: 245_107_195_904,
            usedCapacityBytes: 189_177_487_360,
            availableCapacityBytes: 28_384_145_408,
            purgeableEstimateBytes: 0,
            explainedAllocatedBytes: 143_240_000_000,
            unexplainedBytes: 46_413_327_872,
            inaccessibleKnownLowerBoundBytes: 0,
            unreadablePathCount: 0,
            incompleteCoverage: false,
            coverageStatus: .completeForConfiguredRoots,
            canonicalRootCoverage: [],
            filesystemContributions: [],
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: results,
            coverageDiagnostic: .empty,
            attributionReport: nil,
            physicalReconciliation: nil,
            startedAt: Date(),
            completedAt: Date(),
            duration: 0.1,
            progress: StorageAnalysisProgress(totalStages: 12, completedStages: 12, runningStages: [], state: .completed),
            wasCancelled: false
        )
    }

    // 1. Safety net audits entries
    func testSafetyNetAuditsEntries() throws {
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("Users"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("Library"), withIntermediateDirectories: true)

        let checker = DataVolumeTopLevelSafetyNetChecker(dataVolumeURL: temporaryDirectoryURL)
        let report = checker.audit(reconciliationReport: makeSyntheticReport())

        XCTAssertEqual(report.totalEntriesCount, 3)
        XCTAssertEqual(report.unownedEntriesCount, 0)
        XCTAssertTrue(report.isFullyCovered)
    }

    // 2. Canonical analyzers classified correctly
    func testCanonicalAnalyzersClassified() throws {
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("private"), withIntermediateDirectories: true)

        let checker = DataVolumeTopLevelSafetyNetChecker(dataVolumeURL: temporaryDirectoryURL)
        let report = checker.audit(reconciliationReport: makeSyntheticReport())

        let appEntry = report.entries.first { $0.name == "Applications" }
        XCTAssertEqual(appEntry?.ownershipStatus, .ownedByCanonicalAnalyzer)
        XCTAssertEqual(appEntry?.owningAnalyzerStage, .applications)
        XCTAssertEqual(appEntry?.canonicalOwner, .applications)

        let privEntry = report.entries.first { $0.name == "private" }
        XCTAssertEqual(privEntry?.ownershipStatus, .ownedByCanonicalAnalyzer)
        XCTAssertEqual(privEntry?.owningAnalyzerStage, .privateStorage)
    }

    // 3. Coverage expansion candidates classified (e.g. macOS Install Data)
    func testCoverageExpansionCandidateClassified() throws {
        let installDataURL = temporaryDirectoryURL.appendingPathComponent("macOS Install Data")
        try FileManager.default.createDirectory(at: installDataURL, withIntermediateDirectories: true)

        let candidate = StorageCoverageCandidate(
            originalPath: installDataURL.path,
            normalizedPath: installDataURL.path,
            name: "macOS Install Data",
            scope: .dataVolumeRoot,
            status: .measured,
            allocatedBytes: 3_281_436_000,
            logicalBytes: 3_281_436_000,
            issue: nil,
            exclusionReason: nil,
            contributesToExplainedBytes: true
        )

        let checker = DataVolumeTopLevelSafetyNetChecker(dataVolumeURL: temporaryDirectoryURL)
        let report = checker.audit(reconciliationReport: makeSyntheticReport(coverageExpansionCandidates: [candidate]))

        let entry = report.entries.first { $0.name == "macOS Install Data" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.ownershipStatus, .ownedByCoverageExpansion)
        XCTAssertEqual(entry?.owningAnalyzerStage, .coverageExpansion)
        XCTAssertTrue(entry?.isFilesystemAdditive == true)
    }

    // 4. Intentionally non-additive classified
    func testIntentionallyNonAdditiveClassified() throws {
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("Volumes"), withIntermediateDirectories: true)

        let checker = DataVolumeTopLevelSafetyNetChecker(dataVolumeURL: temporaryDirectoryURL)
        let report = checker.audit(reconciliationReport: makeSyntheticReport())

        let spotlight = report.entries.first { $0.name == ".Spotlight-V100" }
        let volumes = report.entries.first { $0.name == "Volumes" }

        XCTAssertEqual(spotlight?.ownershipStatus, .intentionallyNonAdditive)
        XCTAssertEqual(volumes?.ownershipStatus, .intentionallyNonAdditive)
    }

    // 5. Unowned potential gap detected
    func testUnownedPotentialGapDetected() throws {
        try FileManager.default.createDirectory(at: temporaryDirectoryURL.appendingPathComponent("MysteryNewFolder"), withIntermediateDirectories: true)

        let checker = DataVolumeTopLevelSafetyNetChecker(dataVolumeURL: temporaryDirectoryURL)
        let report = checker.audit(reconciliationReport: makeSyntheticReport())

        let mystery = report.entries.first { $0.name == "MysteryNewFolder" }
        XCTAssertEqual(mystery?.ownershipStatus, .unownedPotentialCoverageGap)
        XCTAssertEqual(report.unownedEntriesCount, 1)
        XCTAssertFalse(report.isFullyCovered)
    }
}
