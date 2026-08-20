import XCTest
@testable import PureMac

final class DataVolumeInternalGapTests: XCTestCase {

    private func makeSyntheticReport(
        dataVolumePhysicalInUse: Int64 = 189_653_327_872, // ~189.65 GB
        explainedBytes: Int64 = 143_240_000_000,          // ~143.24 GB
        purgeableBytes: Int64 = 20_000_000_000,          // ~20.00 GB
        snapshotBytes: Int64 = 5_000_000_000,
        unreadablePathCount: Int = 12,
        analyzerResultsOverride: StorageAnalyzerResults? = nil,
        diagnosticOverride: StorageCoverageDiagnostic? = nil
    ) -> StorageReconciliationReport {
        let unexplained = max(0, dataVolumePhysicalInUse - explainedBytes)

        let snapshot = APFSSnapshotInformation(
            identifier: "snap-1",
            name: "com.apple.TimeMachine.2026-08-20",
            uuid: "UUID-1",
            creationDate: Date(),
            size: snapshotBytes,
            sizeKnowledge: .reportedBySystem,
            type: .timeMachine,
            source: .diskutil,
            storageRelationship: .sharedNonAdditive
        )

        let apfsReport = APFSStorageReport(
            volume: APFSVolumeInformation(
                name: "mac - Data",
                volumeIdentifier: "disk3s1",
                volumeUUID: "UUID-DATA",
                containerIdentifier: "disk3",
                volumeGroupIdentifier: "UUID-GROUP",
                filesystemType: "apfs",
                filesystemKind: .apfs,
                mountPoint: "/System/Volumes/Data",
                dataVolumeRelationship: .dataVolume,
                capacity: APFSVolumeCapacity(
                    totalCapacity: 245_107_195_904,
                    availableCapacity: 27_908_403_200,
                    usedCapacity: dataVolumePhysicalInUse,
                    availableCapacityForImportantUsage: 27_908_403_200 + purgeableBytes,
                    availableCapacityForOpportunisticUsage: 27_908_403_200 + purgeableBytes,
                    purgeableEstimate: purgeableBytes,
                    purgeableEstimateKnowledge: .estimated
                )
            ),
            snapshots: [snapshot],
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )

        let defaultAnalyzerResults = StorageAnalyzerResults(
            userHomeStorage: nil,
            applicationSupport: nil,
            containers: nil,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: nil,
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: apfsReport,
            coverageExpansion: nil,
            physicalReconciliation: nil
        )

        return StorageReconciliationReport(
            totalCapacityBytes: 245_107_195_904,
            usedCapacityBytes: 217_198_792_704, // Container total used
            availableCapacityBytes: 27_908_403_200,
            purgeableEstimateBytes: purgeableBytes,
            explainedAllocatedBytes: explainedBytes,
            unexplainedBytes: unexplained,
            inaccessibleKnownLowerBoundBytes: 500_000_000,
            unreadablePathCount: unreadablePathCount,
            incompleteCoverage: false,
            coverageStatus: .completeForConfiguredRoots,
            canonicalRootCoverage: [],
            filesystemContributions: [],
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: analyzerResultsOverride ?? defaultAnalyzerResults,
            coverageDiagnostic: diagnosticOverride ?? .empty,
            attributionReport: nil,
            physicalReconciliation: nil,
            startedAt: Date(),
            completedAt: Date(),
            duration: 0.5,
            progress: StorageAnalysisProgress(totalStages: 11, completedStages: 11, runningStages: [], state: .completed),
            wasCancelled: false
        )
    }

    // MARK: - Tests

    // 1. Internal-gap calculation (~46.41 GB)
    func testInternalGapCalculation() {
        let rep = makeSyntheticReport(dataVolumePhysicalInUse: 189_653_327_872, explainedBytes: 143_240_000_000)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        XCTAssertEqual(report.dataVolumePhysicalInUseBytes, 189_653_327_872)
        XCTAssertEqual(report.filesystemAttributedBytes, 143_240_000_000)
        XCTAssertEqual(report.internalPhysicalGapBytes, 46_413_327_872)
        XCTAssertEqual(report.unresolvedResidualGapBytes, 46_413_327_872)
    }

    // 2. Logical vs allocated byte distinction
    func testLogicalVsAllocatedDistinction() {
        let node = StorageNode(
            name: "testFile",
            absolutePath: "/test/file",
            logicalSize: 1000,
            allocatedSize: 4096,
            ownLogicalSize: 1000,
            ownAllocatedSize: 4096,
            itemType: .regularFile,
            children: [],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )
        let analysisResult = StorageAnalysisResult(
            root: node,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )

        let analyzerResults = StorageAnalyzerResults(
            userHomeStorage: nil,
            applicationSupport: analysisResult,
            containers: nil,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: nil,
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: nil,
            coverageExpansion: nil,
            physicalReconciliation: nil
        )

        let rep = makeSyntheticReport(analyzerResultsOverride: analyzerResults)

        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        XCTAssertEqual(report.allocationDeltaSummary.totalMeasuredLogicalBytes, 1000)
        XCTAssertEqual(report.allocationDeltaSummary.totalMeasuredAllocatedBytes, 4096)
        XCTAssertEqual(report.allocationDeltaSummary.deltaBytes, 3096)
        XCTAssertTrue(report.allocationDeltaSummary.blockPaddingObserved)
    }

    // 3. Sparse-file handling in allocation diagnostics
    func testSparseFileHandling() {
        let node = StorageNode(
            name: "sparse.img",
            absolutePath: "/test/sparse.img",
            logicalSize: 64_000_000_000,
            allocatedSize: 2_000_000_000,
            ownLogicalSize: 64_000_000_000,
            ownAllocatedSize: 2_000_000_000,
            itemType: .regularFile,
            children: [],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )
        let analysisResult = StorageAnalysisResult(
            root: node,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )

        let analyzerResults = StorageAnalyzerResults(
            userHomeStorage: nil,
            applicationSupport: nil,
            containers: analysisResult,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: nil,
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: nil,
            coverageExpansion: nil,
            physicalReconciliation: nil
        )

        let rep = makeSyntheticReport(analyzerResultsOverride: analyzerResults)

        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        XCTAssertEqual(report.allocationDeltaSummary.totalMeasuredLogicalBytes, 64_000_000_000)
        XCTAssertEqual(report.allocationDeltaSummary.totalMeasuredAllocatedBytes, 2_000_000_000)
        XCTAssertEqual(report.allocationDeltaSummary.deltaBytes, -62_000_000_000)
        XCTAssertTrue(report.allocationDeltaSummary.sparseFilesObserved)
    }

    // 4. Hard-link deduplication preserved
    func testHardLinkDeduplicationPreserved() {
        let rep = makeSyntheticReport()
        XCTAssertEqual(rep.hardLinkAccountingStatus, .deduplicatedWithinAnalyzerScopesOnly)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)
        XCTAssertEqual(report.filesystemAttributedBytes, rep.explainedAllocatedBytes)
    }

    // 5. Clone evidence does not become additive
    func testCloneEvidenceDoesNotBecomeAdditive() {
        let rep = makeSyntheticReport()
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        let cloneItem = report.waterfallItems.first { $0.category == .cloneSharedExtents }
        XCTAssertNotNil(cloneItem)
        XCTAssertEqual(cloneItem?.tier, .presenceOnly)
        XCTAssertNil(cloneItem?.reportedBytes)
        // Clone evidence must not increase additive explained bytes
        XCTAssertEqual(report.additiveExplainedPortionBytes, 0)
    }

    // 6. Purgeable does not reduce residual
    func testPurgeableDoesNotReduceResidual() {
        let rep = makeSyntheticReport(dataVolumePhysicalInUse: 189_653_327_872, explainedBytes: 143_240_000_000, purgeableBytes: 20_000_000_000)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        let purgeableItem = report.waterfallItems.first { $0.category == .purgeableEstimate }
        XCTAssertNotNil(purgeableItem)
        XCTAssertEqual(purgeableItem?.tier, .estimatedOSReported)
        XCTAssertEqual(purgeableItem?.reportedBytes, 20_000_000_000)

        // Invariant: purgeable must NOT reduce the residual gap of 46.41 GB
        XCTAssertEqual(report.internalPhysicalGapBytes, 46_413_327_872)
        XCTAssertEqual(report.unresolvedResidualGapBytes, 46_413_327_872)
        XCTAssertEqual(report.additiveExplainedPortionBytes, 0)
    }

    // 7. Protected paths do not receive fabricated sizes
    func testProtectedPathsDoNotReceiveFabricatedSizes() {
        let issueGroup = StorageCoverageDiagnosticIssueGroup(
            category: .permissionDenied,
            severity: .warning,
            source: .analyzer(.systemLibrary),
            canonicalRoot: .systemLibrary,
            posixErrorCode: 13,
            count: 10,
            representativePaths: ["/System/Volumes/Data/.Spotlight-V100/store.db"],
            explanation: "Permission denied"
        )
        let diag = StorageCoverageDiagnostic(
            measurementIssues: StorageCoverageIssueAggregation(
                totalIssueCount: 10,
                categoryCounts: [],
                analyzerCounts: [],
                canonicalRootCounts: [],
                errnoCounts: [],
                topAffectedParentPaths: [],
                groups: [issueGroup]
            ),
            coverageMap: [],
            coverageGaps: [],
            analyzerStatuses: [],
            unexplainedSpaceExplanations: [],
            explainedStorageConfidence: .completeMeasurement,
            unexplainedStorageConfidence: .knownLowerBound,
            hiddenHomeEntryCount: 0,
            unspecializedLibraryEntryCount: 0
        )
        let rep = makeSyntheticReport(diagnosticOverride: diag)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        let protectedItem = report.waterfallItems.first { $0.category == DataVolumeGapEvidenceCategory.protectedStorage }
        XCTAssertNotNil(protectedItem)
        XCTAssertEqual(protectedItem?.tier, .unknownProtected)
        XCTAssertNil(protectedItem?.reportedBytes) // Must be nil (no fabricated bytes)

        let spotlightFamily = report.protectedSummary.families.first { $0.id == "spotlight" }
        XCTAssertNotNil(spotlightFamily)
        XCTAssertNil(spotlightFamily?.knownLowerBoundBytes)
    }

    // 8. APFS metadata evidence remains non-additive / presence-only
    func testAPFSMetadataEvidenceRemainsPresenceOnly() {
        let rep = makeSyntheticReport()
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        let metadataItem = report.waterfallItems.first { $0.category == .apfsFilesystemMetadata }
        XCTAssertNotNil(metadataItem)
        XCTAssertEqual(metadataItem?.tier, .presenceOnly)
        XCTAssertNil(metadataItem?.reportedBytes)
    }

    // 9. Existing Explained bytes remain unchanged
    func testExistingExplainedBytesRemainUnchanged() {
        let rep = makeSyntheticReport(explainedBytes: 143_240_000_000)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)
        XCTAssertEqual(report.filesystemAttributedBytes, 143_240_000_000)
    }

    // 10. Existing 27.41 GB sibling-volume reconciliation remains intact
    func testSiblingVolumeReconciliationIntact() async {
        let rep = makeSyntheticReport()
        let physicalAnalyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(
                terminationStatus: 0,
                stdout: APFSPhysicalReconciliationTests().sampleAPFSListPlistDataForTesting,
                stderr: Data(),
                launchError: nil,
                wasCancelled: false
            )
        })
        let physicalReport = await physicalAnalyzer.analyze(reconciliationReport: rep)

        XCTAssertEqual(physicalReport.metrics.containerSiblingVolumesBytes, 27_365_883_904)
        XCTAssertNotNil(physicalReport.dataVolumeInternalGap)
        XCTAssertEqual(physicalReport.dataVolumeInternalGap?.internalPhysicalGapBytes, 46_413_327_872)
    }

    // 11. Data volume and container accounting remain distinct
    func testDataVolumeAndContainerAccountingDistinct() async {
        let rep = makeSyntheticReport()
        let physicalAnalyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(
                terminationStatus: 0,
                stdout: APFSPhysicalReconciliationTests().sampleAPFSListPlistDataForTesting,
                stderr: Data(),
                launchError: nil,
                wasCancelled: false
            )
        })
        let physicalReport = await physicalAnalyzer.analyze(reconciliationReport: rep)

        // Container physical gap: 73.96 GB
        XCTAssertEqual(physicalReport.metrics.physicalAccountingGapBytes, 73_958_792_704)
        // Data volume internal gap: 46.41 GB
        XCTAssertEqual(physicalReport.metrics.dataVolumeInternalGapBytes, 46_413_327_872)
        XCTAssertNotEqual(physicalReport.metrics.physicalAccountingGapBytes, physicalReport.metrics.dataVolumeInternalGapBytes)
    }

    // 12. Unknown evidence remains unknown
    func testUnknownEvidenceRemainsUnknown() {
        let rep = makeSyntheticReport()
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        let residual = report.waterfallItems.first { $0.category == .unresolvedResidual }
        XCTAssertNotNil(residual)
        XCTAssertEqual(residual?.tier, .unknownProtected)
        XCTAssertEqual(residual?.badgeText, "Unresolved")
    }

    // 13. Additive evidence is the only evidence allowed to reduce a diagnostic residual
    func testOnlyAdditiveEvidenceReducesResidual() {
        let rep = makeSyntheticReport(dataVolumePhysicalInUse: 189_653_327_872, explainedBytes: 143_240_000_000)
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        // Even though non-additive evidence exists (purgeable ~20GB, snapshots ~5GB),
        // additiveExplainedPortionBytes is strictly 0 and residual is NOT reduced.
        XCTAssertEqual(report.additiveExplainedPortionBytes, 0)
        XCTAssertEqual(report.unresolvedResidualGapBytes, 46_413_327_872)
    }

    // 14. Cancellation support
    func testCancellation() {
        var rep = makeSyntheticReport()
        rep = StorageReconciliationReport(
            totalCapacityBytes: rep.totalCapacityBytes,
            usedCapacityBytes: rep.usedCapacityBytes,
            availableCapacityBytes: rep.availableCapacityBytes,
            purgeableEstimateBytes: rep.purgeableEstimateBytes,
            explainedAllocatedBytes: rep.explainedAllocatedBytes,
            unexplainedBytes: rep.unexplainedBytes,
            inaccessibleKnownLowerBoundBytes: rep.inaccessibleKnownLowerBoundBytes,
            unreadablePathCount: rep.unreadablePathCount,
            incompleteCoverage: rep.incompleteCoverage,
            coverageStatus: rep.coverageStatus,
            canonicalRootCoverage: rep.canonicalRootCoverage,
            filesystemContributions: rep.filesystemContributions,
            hardLinkAccountingStatus: rep.hardLinkAccountingStatus,
            analysisIssues: rep.analysisIssues,
            analyzerResults: rep.analyzerResults,
            coverageDiagnostic: rep.coverageDiagnostic,
            attributionReport: rep.attributionReport,
            physicalReconciliation: rep.physicalReconciliation,
            startedAt: rep.startedAt,
            completedAt: rep.completedAt,
            duration: rep.duration,
            progress: rep.progress,
            wasCancelled: true
        )

        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)
        XCTAssertTrue(report.wasCancelled)
    }

    // 15. Command timeout / failure
    func testCommandFailureSafety() async {
        let rep = makeSyntheticReport()
        let physicalAnalyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: "Query timeout".data(using: .utf8)!,
                launchError: nil,
                wasCancelled: false
            )
        })
        let physicalReport = await physicalAnalyzer.analyze(reconciliationReport: rep)

        XCTAssertFalse(physicalReport.issues.isEmpty)
        XCTAssertNotNil(physicalReport.dataVolumeInternalGap)
    }

    // 16. UI/state presentation
    @MainActor
    func testUIPresentationIntegration() async {
        let rep = makeSyntheticReport()
        let physicalAnalyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(
                terminationStatus: 0,
                stdout: APFSPhysicalReconciliationTests().sampleAPFSListPlistDataForTesting,
                stderr: Data(),
                launchError: nil,
                wasCancelled: false
            )
        })
        let physicalReport = await physicalAnalyzer.analyze(reconciliationReport: rep)

        let finalReport = StorageReconciliationReport(
            totalCapacityBytes: rep.totalCapacityBytes,
            usedCapacityBytes: rep.usedCapacityBytes,
            availableCapacityBytes: rep.availableCapacityBytes,
            purgeableEstimateBytes: rep.purgeableEstimateBytes,
            explainedAllocatedBytes: rep.explainedAllocatedBytes,
            unexplainedBytes: rep.unexplainedBytes,
            inaccessibleKnownLowerBoundBytes: rep.inaccessibleKnownLowerBoundBytes,
            unreadablePathCount: rep.unreadablePathCount,
            incompleteCoverage: rep.incompleteCoverage,
            coverageStatus: rep.coverageStatus,
            canonicalRootCoverage: rep.canonicalRootCoverage,
            filesystemContributions: rep.filesystemContributions,
            hardLinkAccountingStatus: rep.hardLinkAccountingStatus,
            analysisIssues: rep.analysisIssues,
            analyzerResults: rep.analyzerResults,
            coverageDiagnostic: rep.coverageDiagnostic,
            attributionReport: rep.attributionReport,
            physicalReconciliation: physicalReport,
            startedAt: rep.startedAt,
            completedAt: rep.completedAt,
            duration: rep.duration,
            progress: rep.progress,
            wasCancelled: rep.wasCancelled
        )

        let state = StorageIntelligenceState(
            analysisRunner: { _ in finalReport }
        )
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertNotNil(state.physicalReconciliationPresentation?.report.dataVolumeInternalGap)
        XCTAssertEqual(
            state.physicalReconciliationPresentation?.report.dataVolumeInternalGap?.internalPhysicalGapBytes,
            46_413_327_872
        )
    }

    // 17. Full regression suite integration
    func testFullRegressionSuiteIntegration() {
        let rep = makeSyntheticReport()
        let analyzer = DataVolumeInternalGapAnalyzer()
        let report = analyzer.analyze(reconciliationReport: rep, dataVolumePhysicalInUse: 189_653_327_872)

        XCTAssertFalse(report.waterfallItems.isEmpty)
        XCTAssertEqual(report.waterfallItems.count, 7)
    }
}

extension APFSPhysicalReconciliationTests {
    var sampleAPFSListPlistDataForTesting: Data {
        sampleAPFSListPlistData
    }
}
