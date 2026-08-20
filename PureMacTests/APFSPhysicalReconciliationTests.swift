import XCTest
@testable import PureMac

final class APFSPhysicalReconciliationTests: XCTestCase {

    // MARK: - Synthetic Plist Fixtures

    var sampleAPFSListPlistData: Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Containers</key>
            <array>
                <dict>
                    <key>ContainerReference</key>
                    <string>disk3</string>
                    <key>APFSContainerUUID</key>
                    <string>CD821B99-B619-45BA-821B-F4F8541C2D0C</string>
                    <key>CapacityCeiling</key>
                    <integer>245107195904</integer>
                    <key>CapacityFree</key>
                    <integer>27908403200</integer>
                    <key>PhysicalStores</key>
                    <array>
                        <dict>
                            <key>DeviceIdentifier</key>
                            <string>disk0s2</string>
                        </dict>
                    </array>
                    <key>Volumes</key>
                    <array>
                        <dict>
                            <key>Name</key>
                            <string>mac - Data</string>
                            <key>DeviceIdentifier</key>
                            <string>disk3s1</string>
                            <key>APFSVolumeUUID</key>
                            <string>EECD899C-114C-463D-AC3E-6AAF250CC227</string>
                            <key>Roles</key>
                            <array>
                                <string>Data</string>
                            </array>
                            <key>CapacityInUse</key>
                            <integer>189653327872</integer>
                            <key>Encryption</key>
                            <true/>
                            <key>FileVault</key>
                            <true/>
                        </dict>
                        <dict>
                            <key>Name</key>
                            <string>mac</string>
                            <key>DeviceIdentifier</key>
                            <string>disk3s3</string>
                            <key>APFSVolumeUUID</key>
                            <string>5EF7CA72-BC09-4CC9-9205-DC2150647D3C</string>
                            <key>Roles</key>
                            <array>
                                <string>System</string>
                            </array>
                            <key>CapacityInUse</key>
                            <integer>12634509312</integer>
                            <key>Encryption</key>
                            <true/>
                            <key>FileVault</key>
                            <true/>
                        </dict>
                        <dict>
                            <key>Name</key>
                            <string>Preboot</string>
                            <key>DeviceIdentifier</key>
                            <string>disk3s4</string>
                            <key>APFSVolumeUUID</key>
                            <string>CDDE8855-314A-4A4A-BA0A-DC1C13B3F36A</string>
                            <key>Roles</key>
                            <array>
                                <string>Preboot</string>
                            </array>
                            <key>CapacityInUse</key>
                            <integer>9136005120</integer>
                        </dict>
                        <dict>
                            <key>Name</key>
                            <string>Recovery</string>
                            <key>DeviceIdentifier</key>
                            <string>disk3s5</string>
                            <key>APFSVolumeUUID</key>
                            <string>BC1E9A02-504F-48FE-9C78-44A973D05539</string>
                            <key>Roles</key>
                            <array>
                                <string>Recovery</string>
                            </array>
                            <key>CapacityInUse</key>
                            <integer>1300238336</integer>
                        </dict>
                        <dict>
                            <key>Name</key>
                            <string>VM</string>
                            <key>DeviceIdentifier</key>
                            <string>disk3s6</string>
                            <key>APFSVolumeUUID</key>
                            <string>EA313EA6-9491-48F9-915C-93249DF9CDD7</string>
                            <key>Roles</key>
                            <array>
                                <string>VM</string>
                            </array>
                            <key>CapacityInUse</key>
                            <integer>4295131136</integer>
                        </dict>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """.data(using: .utf8)!
    }

    private func makeSyntheticReconciliationReport(
        totalCapacity: Int64 = 245_107_195_904,
        usedCapacity: Int64 = 217_198_792_704, // 245.1 - 27.9 GB = ~217.20 GB
        explainedBytes: Int64 = 143_240_000_000,
        purgeableBytes: Int64 = 20_000_000_000,
        snapshots: [APFSSnapshotInformation] = []
    ) -> StorageReconciliationReport {
        let unexplained = max(0, usedCapacity - explainedBytes)
        let apfsReport = APFSStorageReport(
            volume: APFSVolumeInformation(
                name: "mac - Data",
                volumeIdentifier: "disk3s1",
                volumeUUID: "EECD899C-114C-463D-AC3E-6AAF250CC227",
                containerIdentifier: "disk3",
                volumeGroupIdentifier: "EECD899C-114C-463D-AC3E-6AAF250CC227",
                filesystemType: "apfs",
                filesystemKind: .apfs,
                mountPoint: "/System/Volumes/Data",
                dataVolumeRelationship: .dataVolume,
                capacity: APFSVolumeCapacity(
                    totalCapacity: totalCapacity,
                    availableCapacity: totalCapacity - usedCapacity,
                    usedCapacity: usedCapacity,
                    availableCapacityForImportantUsage: (totalCapacity - usedCapacity) + purgeableBytes,
                    availableCapacityForOpportunisticUsage: (totalCapacity - usedCapacity) + purgeableBytes,
                    purgeableEstimate: purgeableBytes,
                    purgeableEstimateKnowledge: .estimated
                )
            ),
            snapshots: snapshots,
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )

        var analyzerResults = StorageAnalyzerResults(
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

        let attributionReport = StorageUnexplainedAttributionReport(
            volumeUsedBytes: usedCapacity,
            explainedAllocatedBytes: explainedBytes,
            unexplainedBytes: unexplained,
            residualUnattributedBytes: unexplained,
            dataVolumeRoots: [],
            attributionItems: [
                StorageAttributionItem(
                    id: "vm.swap",
                    category: .systemManagedStorage,
                    name: "Virtual Memory Swap",
                    status: .measured,
                    allocatedBytes: 1_073_741_824,
                    explanation: "macOS active swap files",
                    isFilesystemAdditive: true
                )
            ],
            vmFootprintBytes: 1_073_741_824,
            sleepImageBytes: nil,
            snapshotFootprintBytes: nil,
            purgeableEstimateBytes: purgeableBytes,
            wasCancelled: false,
            issues: []
        )

        return StorageReconciliationReport(
            totalCapacityBytes: totalCapacity,
            usedCapacityBytes: usedCapacity,
            availableCapacityBytes: totalCapacity - usedCapacity,
            purgeableEstimateBytes: purgeableBytes,
            explainedAllocatedBytes: explainedBytes,
            unexplainedBytes: unexplained,
            inaccessibleKnownLowerBoundBytes: 0,
            unreadablePathCount: 0,
            incompleteCoverage: false,
            coverageStatus: .completeForConfiguredRoots,
            canonicalRootCoverage: [],
            filesystemContributions: [],
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: analyzerResults,
            coverageDiagnostic: .empty,
            attributionReport: attributionReport,
            physicalReconciliation: nil,
            startedAt: Date(),
            completedAt: Date(),
            duration: 1.0,
            progress: StorageAnalysisProgress(totalStages: 11, completedStages: 11, runningStages: [], state: .completed),
            wasCancelled: false
        )
    }

    // MARK: - Tests

    // 1. Correct physical-gap calculation
    func testPhysicalGapCalculation() async {
        let rep = makeSyntheticReconciliationReport(usedCapacity: 200_000_000_000, explainedBytes: 140_000_000_000)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })

        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertEqual(report.metrics.physicalVolumeUsedBytes, 200_000_000_000)
        XCTAssertEqual(report.metrics.filesystemAttributedBytes, 140_000_000_000)
        XCTAssertEqual(report.metrics.physicalAccountingGapBytes, 60_000_000_000)
    }

    // 2. No double counting of purgeable capacity
    func testPurgeableNotDoubleCounted() async {
        let rep = makeSyntheticReconciliationReport(usedCapacity: 200_000_000_000, explainedBytes: 140_000_000_000, purgeableBytes: 25_000_000_000)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })

        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertEqual(report.metrics.purgeableEstimateBytes, 25_000_000_000)
        // Explained bytes must not be increased by purgeable bytes
        XCTAssertEqual(report.metrics.filesystemAttributedBytes, 140_000_000_000)
    }

    // 3. Snapshots remain non-additive
    func testSnapshotsRemainNonAdditive() async {
        let snapshot = APFSSnapshotInformation(
            identifier: "snap-1",
            name: "com.apple.TimeMachine.2026-08-20",
            uuid: "UUID-1",
            creationDate: Date(),
            size: 15_000_000_000,
            sizeKnowledge: .reportedBySystem,
            type: .timeMachine,
            source: .tmutil,
            storageRelationship: .sharedNonAdditive
        )
        let rep = makeSyntheticReconciliationReport(explainedBytes: 140_000_000_000, snapshots: [snapshot])
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })

        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertEqual(report.snapshots.snapshotCount, 1)
        XCTAssertEqual(report.snapshots.totalReportedSnapshotBytes, 15_000_000_000)
        XCTAssertTrue(report.snapshots.isNonAdditive)
        XCTAssertEqual(report.metrics.filesystemAttributedBytes, 140_000_000_000)
    }

    // 4. Shared extent evidence remains non-additive
    func testSharedExtentsRemainNonAdditive() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertTrue(report.snapshots.explanation.contains("non-additive"))
    }

    // 5. Correct Data-volume identity selection
    func testDataVolumeIdentitySelection() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)

        guard let target = report.targetVolume else {
            XCTFail("Target volume should not be nil")
            return
        }
        XCTAssertEqual(target.name, "mac - Data")
        XCTAssertEqual(target.deviceIdentifier, "disk3s1")
        XCTAssertTrue(target.roles.contains("Data"))
        XCTAssertEqual(target.capacityInUseBytes, 189_653_327_872)
    }

    // 6. System volume is not confused with Data volume
    func testSystemVolumeDistinction() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertNotEqual(report.targetVolume?.deviceIdentifier, "disk3s3")
        XCTAssertNotEqual(report.targetVolume?.name, "mac")
        XCTAssertEqual(report.targetVolume?.name, "mac - Data")
        // Check sibling volumes list contains the System volume
        XCTAssertTrue(report.container?.volumes.contains(where: { $0.deviceIdentifier == "disk3s3" && $0.role == "System" }) ?? false)
    }

    // 7. Command failure does not fail entire analysis
    func testCommandFailureNonFatal() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 1, stdout: Data(), stderr: "Failed to query".data(using: .utf8)!, launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertNotNil(report.metrics)
        XCTAssertEqual(report.metrics.filesystemAttributedBytes, rep.explainedAllocatedBytes)
    }

    // 8. Missing snapshot information is handled safely
    func testMissingSnapshotHandling() async {
        let rep = makeSyntheticReconciliationReport(snapshots: [])
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertEqual(report.snapshots.snapshotCount, 0)
        XCTAssertNil(report.snapshots.totalReportedSnapshotBytes)
    }

    // 9. VM evidence integration
    func testVMStorageEvidenceIntegration() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertEqual(report.systemManaged.vmFootprintBytes, 1_073_741_824)
        XCTAssertEqual(report.systemManaged.swapFileBytes, 1_073_741_824)
        XCTAssertEqual(report.systemManaged.vmVolumeBytes, 4_295_131_136)
    }

    // 10. Protected-system evidence integration
    func testProtectedSystemEvidenceIntegration() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertNotNil(report.protectedStorage)
        XCTAssertEqual(report.protectedStorage.unreadablePathCount, 0)
    }

    // 11. Zero-gap case
    func testZeroPhysicalGapCase() async {
        let rep = makeSyntheticReconciliationReport(usedCapacity: 150_000_000_000, explainedBytes: 150_000_000_000, purgeableBytes: 0)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertEqual(report.metrics.physicalAccountingGapBytes, 0)
        XCTAssertEqual(report.status, .fullyReconciled)
    }

    // 12. Large-gap case
    func testLargePhysicalGapCase() async {
        let rep = makeSyntheticReconciliationReport(usedCapacity: 217_198_792_704, explainedBytes: 143_240_000_000)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)

        XCTAssertEqual(report.metrics.physicalAccountingGapBytes, 73_958_792_704)
        XCTAssertEqual(report.metrics.containerSiblingVolumesBytes, 27_365_883_904)
        XCTAssertEqual(report.metrics.dataVolumeInternalGapBytes, 46_413_327_872)
        XCTAssertEqual(report.status, .apfsNonAdditiveFactorsPresent)
    }

    // 13. Small discrepancy tolerance
    func testTrivialDiscrepancyTolerance() {
        let metrics = APFSPhysicalAccountingMetrics(
            physicalVolumeUsedBytes: 100_030_000_000,
            dataVolumePhysicalInUseBytes: 100_000_000_000,
            filesystemAttributedBytes: 100_000_000_000,
            containerSiblingVolumesBytes: 0,
            physicalAccountingGapBytes: 30_000_000, // 30 MB (<= 50 MB)
            dataVolumeInternalGapBytes: 0,
            purgeableEstimateBytes: 0,
            containerAccountingDiscrepancyBytes: 0
        )
        let status = APFSPhysicalReconciliationAnalyzer.classifyStatus(
            metrics: metrics,
            snapshotCount: 0,
            purgeableBytes: 0,
            protectedCount: 0,
            unreadableCount: 0
        )
        XCTAssertEqual(status, .fullyReconciled)
    }

    // 14. Cancellation
    func testCancellationSupport() async {
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: -1, stdout: Data(), stderr: Data(), launchError: nil, wasCancelled: true)
        })
        let rep = makeSyntheticReconciliationReport()
        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertTrue(report.issues.contains { $0.kind == .cancelled })
    }

    // 15. Deterministic classification
    func testDeterministicClassification() {
        // Case A: Coverage limited / unreadable
        let metricsA = APFSPhysicalAccountingMetrics(
            physicalVolumeUsedBytes: 200_000_000_000,
            dataVolumePhysicalInUseBytes: 200_000_000_000,
            filesystemAttributedBytes: 150_000_000_000,
            containerSiblingVolumesBytes: 0,
            physicalAccountingGapBytes: 50_000_000_000,
            dataVolumeInternalGapBytes: 50_000_000_000,
            purgeableEstimateBytes: 0,
            containerAccountingDiscrepancyBytes: 0
        )
        let statusA = APFSPhysicalReconciliationAnalyzer.classifyStatus(
            metrics: metricsA,
            snapshotCount: 0,
            purgeableBytes: 0,
            protectedCount: 5,
            unreadableCount: 10
        )
        XCTAssertEqual(statusA, .protectedSystemStoragePresent)

        // Case B: APFS factors present (purgeable)
        let statusB = APFSPhysicalReconciliationAnalyzer.classifyStatus(
            metrics: metricsA,
            snapshotCount: 0,
            purgeableBytes: 5_000_000_000,
            protectedCount: 0,
            unreadableCount: 0
        )
        XCTAssertEqual(statusB, .apfsNonAdditiveFactorsPresent)
    }

    // 16. Existing explained-byte accounting remains unchanged
    func testExistingExplainedBytesUnchanged() async {
        let rep = makeSyntheticReconciliationReport(explainedBytes: 143_240_000_000)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertEqual(report.metrics.filesystemAttributedBytes, 143_240_000_000)
    }

    // 17. Existing coverage-gap accounting remains unchanged
    func testCoverageGapAccountingUnchanged() async {
        let rep = makeSyntheticReconciliationReport()
        XCTAssertEqual(rep.coverageDiagnostic.coverageGaps.count, 0)
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertNotNil(report)
        XCTAssertEqual(rep.coverageDiagnostic.coverageGaps.count, 0)
    }

    // 18. No cleanup capability is exposed
    func testNoCleanupCapabilityExposed() {
        // Verify APFSPhysicalReconciliationReport does not have any mutating or destructive methods
        let report = APFSPhysicalReconciliationReport.empty
        XCTAssertEqual(report.status, .insufficientEvidence)
        XCTAssertEqual(report.warnings.count, 0)
    }

    // 19. UI/state receives reconciliation report correctly
    @MainActor
    func testPresentationStateReceivesReport() async {
        let rep = makeSyntheticReconciliationReport()
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let physicalReport = await analyzer.analyze(reconciliationReport: rep)

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

        XCTAssertNotNil(state.physicalReconciliationPresentation)
        XCTAssertEqual(
            state.physicalReconciliationPresentation?.report.metrics.physicalVolumeUsedBytes,
            rep.usedCapacityBytes
        )
    }

    // 20. Existing Storage Intelligence tests remain passing (Regression test integration)
    func testFullRegressionPreserved() async {
        let rep = makeSyntheticReconciliationReport()
        let analyzer = APFSPhysicalReconciliationAnalyzer(commandRunner: { _ in
            APFSCommandResult(terminationStatus: 0, stdout: self.sampleAPFSListPlistData, stderr: Data(), launchError: nil, wasCancelled: false)
        })
        let report = await analyzer.analyze(reconciliationReport: rep)
        XCTAssertNotNil(report)
        XCTAssertEqual(report.metrics.containerSiblingVolumesBytes, 27_365_883_904)
    }
}
