import XCTest
@testable import PureMac

@MainActor
final class StorageIntelligenceStateTests: XCTestCase {
    func testInitialStateIsIdle() {
        let state = Self.makeState()

        XCTAssertEqual(state.lifecycle, .idle)
        XCTAssertNil(state.report)
        XCTAssertTrue(state.canAnalyze)
        XCTAssertFalse(state.canCancel)
    }

    func testScanStarts() async {
        let report = Self.report()
        let state = StorageIntelligenceState(analysisRunner: { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return report
        })

        state.analyze()

        XCTAssertEqual(state.lifecycle, .running)
        XCTAssertTrue(state.canCancel)
        state.cancel()
        await state.waitForAnalysis()
    }

    func testProgressUpdatesWhileScanRuns() async {
        let report = Self.report()
        let update = StorageAnalysisProgress(
            totalStages: 10,
            completedStages: 3,
            runningStages: [.containers],
            state: .running
        )
        let state = StorageIntelligenceState(analysisRunner: { progress in
            await progress(update)
            try await Task.sleep(nanoseconds: 500_000_000)
            return report
        })

        state.analyze()
        await Self.waitUntil { state.progress == update }

        XCTAssertEqual(state.progress, update)
        state.cancel()
        await state.waitForAnalysis()
    }

    func testSuccessfulReportCompletes() async {
        let expected = Self.report()
        let state = Self.makeState(report: expected)

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.lifecycle, .completed)
        XCTAssertEqual(state.report, expected)
        XCTAssertTrue(state.hasCompletedReport)
        XCTAssertNil(state.errorMessage)
    }

    func testPartialReportIsPresentedAsIncompleteCoverage() async {
        let expected = Self.report(
            coverage: .partialDueToPermissions,
            unreadablePathCount: 3,
            knownLowerBound: 5
        )
        let state = Self.makeState(report: expected)

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.coverage?.status, .partialDueToPermissions)
        XCTAssertEqual(state.coverage?.unreadablePathCount, 3)
        XCTAssertEqual(state.coverage?.knownLowerBoundBytes, 5)
        XCTAssertEqual(state.coverage?.isPartial, true)
    }

    func testCancellationProducesCancelledState() async {
        let report = Self.report()
        let state = StorageIntelligenceState(analysisRunner: { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return report
        })

        state.analyze()
        state.cancel()
        await state.waitForAnalysis()

        XCTAssertEqual(state.lifecycle, .cancelled)
        XCTAssertEqual(state.progress?.state, .cancelled)
        XCTAssertFalse(state.isRunning)
    }

    func testAnalyzerFailureIsPresented() async {
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "Fixture failed" }
        }
        let state = StorageIntelligenceState(analysisRunner: { _ in
            throw ExpectedFailure()
        })

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.lifecycle, .failed)
        XCTAssertTrue(state.errorMessage?.contains("Fixture failed") == true)
        XCTAssertNil(state.report)
    }

    func testExplainedAndUnexplainedUseReportAllocatedSemantics() async {
        let state = Self.makeState(report: Self.report(
            total: 1_000,
            used: 800,
            free: 200,
            explained: 325,
            unexplained: 475
        ))

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.explainedAllocatedBytes, 325)
        XCTAssertEqual(state.summary?.unexplainedBytes, 475)
        XCTAssertEqual(state.summary?.usedBytes, 800)
    }

    func testPurgeableEstimateRemainsSeparate() async {
        let state = Self.makeState(report: Self.report(
            explained: 65,
            unexplained: 735,
            purgeable: 120
        ))

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.purgeableEstimateBytes, 120)
        XCTAssertEqual(state.summary?.explainedAllocatedBytes, 65)
        XCTAssertEqual(state.summary?.unexplainedBytes, 735)
    }

    func testDockerRuntimeDoesNotAlterLocalTotal() async {
        let docker = Self.dockerReport(runtimeBytes: 50_000, location: .local)
        let expected = Self.report(explained: 65, docker: docker)
        let state = Self.makeState(report: expected)

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.explainedAllocatedBytes, 65)
        XCTAssertEqual(state.dockerPresentation?.localFootprintBytes, 15)
        XCTAssertEqual(state.dockerPresentation?.runtimeReportedBytes, 50_000)
        XCTAssertEqual(state.dockerPresentation?.runtimeIsNonAdditive, true)
    }

    func testRemoteDockerRuntimeMessaging() async {
        let state = Self.makeState(report: Self.report(
            docker: Self.dockerReport(runtimeBytes: 90_000, location: .remote)
        ))

        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.dockerPresentation?.runtimeLocation, .remote)
        XCTAssertEqual(
            state.dockerPresentation?.relationshipMessage,
            "Remote Docker context. Runtime storage is not stored on this Mac."
        )
    }

    func testAPFSSnapshotWithUnknownSizeStaysUnknown() async {
        let state = Self.makeState(report: Self.report(apfs: Self.apfsReport(snapshotSize: nil)))

        state.analyze()
        await state.waitForAnalysis()

        let snapshot = state.apfsPresentation?.snapshots.first
        XCTAssertNil(snapshot?.sizeBytes)
        XCTAssertEqual(snapshot?.sizeIsReliable, false)
        XCTAssertEqual(snapshot?.isNonAdditive, true)
    }

    func testSortingByAllocatedSizeDescending() async {
        let state = Self.makeState()

        state.analyze()
        await state.waitForAnalysis()

        let roots = state.categories.first { $0.id == .applicationSupport }?.roots
        XCTAssertEqual(roots?.map(\.name), ["rootfs.img", "Beta", "Alpha", "Secret"])
    }

    func testSortingByName() async {
        let state = Self.makeState()
        state.analyze()
        await state.waitForAnalysis()

        state.updateSortOrder(.name)
        await state.waitForPresentation()

        let roots = state.categories.first { $0.id == .applicationSupport }?.roots
        XCTAssertEqual(roots?.map(\.name), ["Alpha", "Beta", "rootfs.img", "Secret"])
    }

    func testSearchMatchesNodeName() async {
        let state = Self.makeState()
        await Self.analyze(state)

        state.updateSearch("rootfs")
        await state.waitForSearch()

        XCTAssertEqual(state.searchResults.map(\.node.name), ["rootfs.img"])
    }

    func testSearchMatchesPath() async {
        let state = Self.makeState()
        await Self.analyze(state)

        state.updateSearch("/application support/secret")
        await state.waitForSearch()

        XCTAssertEqual(state.searchResults.map(\.node.name), ["Secret"])
    }

    func testSearchMatchesOwningApplication() async {
        let state = Self.makeState()
        await Self.analyze(state)

        state.updateSearch("verified app")
        await state.waitForSearch()

        XCTAssertEqual(state.searchResults.map(\.node.name), ["Beta"])
    }

    func testSearchDoesNotMutateReport() async {
        let expected = Self.report()
        let state = Self.makeState(report: expected)
        await Self.analyze(state)

        state.updateSearch("alpha")
        await state.waitForSearch()
        state.updateSearch("beta")
        await state.waitForSearch()

        XCTAssertEqual(state.report, expected)
    }

    func testUnusuallyLargeMetadataIsPresented() async {
        let state = Self.makeState()
        await Self.analyze(state)

        let prominent = state.categories
            .first { $0.id == .applicationSupport }?
            .prominentNode
        XCTAssertEqual(prominent?.name, "rootfs.img")
        XCTAssertEqual(prominent?.isUnusuallyLarge, true)
    }

    func testInaccessibleNodeIsPresentedAsIncomplete() async {
        let state = Self.makeState()
        await Self.analyze(state)
        state.updateSearch("secret")
        await state.waitForSearch()

        let node = state.searchResults.first?.node
        XCTAssertEqual(node?.accessibility, .inaccessible)
        XCTAssertEqual(node?.hasIncompleteMeasurement, true)
        XCTAssertEqual(node?.issueCount, 1)
    }

    func testSparseVirtualDiskPreservesLogicalAndAllocatedValues() async {
        let state = Self.makeState()
        await Self.analyze(state)
        state.updateSearch("rootfs")
        await state.waitForSearch()

        let node = state.searchResults.first?.node
        XCTAssertEqual(node?.allocatedSize, 30)
        XCTAssertEqual(node?.logicalSize, 3_000_000)
        XCTAssertEqual(node?.isVirtualDisk, true)
        XCTAssertEqual(node?.isSparseVirtualDisk, true)
        XCTAssertEqual(node?.hasMaterialLogicalDifference, true)
    }

    func testRevealInFinderEligibilityUsesPathExistence() {
        let node = StorageNodePresentation(node: Self.node(path: "/exists", allocated: 1))
        let existing = StorageIntelligenceState(
            analysisRunner: { _ in Self.report() },
            pathExists: { $0 == "/exists" }
        )
        let missing = StorageIntelligenceState(
            analysisRunner: { _ in Self.report() },
            pathExists: { _ in false }
        )

        XCTAssertTrue(existing.canRevealInFinder(node))
        XCTAssertFalse(missing.canRevealInFinder(node))
    }

    func testStateExposesNoCleanupAction() {
        let state = Self.makeState()

        XCTAssertEqual(state.availableActions, [
            .analyze,
            .cancel,
            .search,
            .sort,
            .navigate,
            .revealInFinder,
            .permissionGuidance,
            .viewDiagnostics,
        ])
    }

    func testRescanReplacesPriorReport() async {
        let first = Self.report(used: 700, explained: 65, unexplained: 635)
        let second = Self.report(used: 900, explained: 165, unexplained: 735)
        let sequence = ReportSequence([first, second])
        let state = StorageIntelligenceState(analysisRunner: { _ in
            await sequence.next()
        })

        await Self.analyze(state)
        XCTAssertEqual(state.summary?.usedBytes, 700)
        await Self.analyze(state)

        XCTAssertEqual(state.report, second)
        XCTAssertEqual(state.summary?.usedBytes, 900)
        XCTAssertEqual(state.summary?.explainedAllocatedBytes, 165)
    }

    func testCancellationDoesNotRetainStaleRunningState() async {
        let report = Self.report()
        let state = StorageIntelligenceState(analysisRunner: { _ in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                // Simulate a dependency that returns a partial report after cancellation.
            }
            return report
        })

        state.analyze()
        state.cancel()
        await state.waitForAnalysis()

        XCTAssertEqual(state.lifecycle, .cancelled)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.progress?.state, .completed)
    }
}

// MARK: - Fixtures

private extension StorageIntelligenceStateTests {
    static func makeState() -> StorageIntelligenceState {
        Self.makeState(report: Self.report())
    }

    static func makeState(
        report: StorageReconciliationReport
    ) -> StorageIntelligenceState {
        StorageIntelligenceState(analysisRunner: { _ in report })
    }

    static func analyze(_ state: StorageIntelligenceState) async {
        state.analyze()
        await state.waitForAnalysis()
    }

    static func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    nonisolated static func report(
        total: Int64 = 1_000,
        used: Int64 = 800,
        free: Int64 = 200,
        explained: Int64 = 65,
        unexplained: Int64? = 735,
        purgeable: Int64? = 100,
        coverage: StorageCoverageStatus = .completeForConfiguredRoots,
        unreadablePathCount: Int = 0,
        knownLowerBound: Int64 = 0,
        docker: DockerStorageReport? = nil,
        apfs: APFSStorageReport? = nil
    ) -> StorageReconciliationReport {
        let applicationSupport = applicationSupportResult()
        let contribution = StorageFilesystemContribution(
            source: .applicationSupport,
            absolutePath: applicationSupport.root.absolutePath,
            normalizedPath: applicationSupport.root.absolutePath,
            observedAllocatedBytes: applicationSupport.root.allocatedSize,
            accountedAllocatedBytes: explained,
            relationship: .canonicalUnique,
            owningPath: nil
        )
        let now = Date(timeIntervalSince1970: 1)
        return StorageReconciliationReport(
            totalCapacityBytes: total,
            usedCapacityBytes: used,
            availableCapacityBytes: free,
            purgeableEstimateBytes: purgeable,
            explainedAllocatedBytes: explained,
            unexplainedBytes: unexplained,
            inaccessibleKnownLowerBoundBytes: knownLowerBound,
            unreadablePathCount: unreadablePathCount,
            incompleteCoverage: coverage != .completeForConfiguredRoots,
            coverageStatus: coverage,
            canonicalRootCoverage: [],
            filesystemContributions: [contribution],
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: StorageAnalyzerResults(
                userHomeStorage: nil,
                applicationSupport: applicationSupport,
                containers: nil,
                groupContainers: nil,
                systemLibrary: nil,
                privateStorage: nil,
                dataVolumeHiddenStorage: nil,
                developerSystemStorage: nil,
                dockerStorage: docker,
                apfsStorage: apfs
            ),
            coverageDiagnostic: .empty,
            startedAt: now,
            completedAt: now,
            duration: 0,
            progress: StorageAnalysisProgress(
                totalStages: 10,
                completedStages: 10,
                runningStages: [],
                state: .completed
            ),
            wasCancelled: false
        )
    }

    nonisolated static func applicationSupportResult() -> StorageAnalysisResult {
        let issue = StorageScanIssue(
            path: "/Users/test/Library/Application Support/Secret",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )
        let children = [
            node(path: "/Users/test/Library/Application Support/Alpha", allocated: 10),
            node(
                path: "/Users/test/Library/Application Support/Beta",
                allocated: 20,
                metadata: StorageAnalysisMetadata(owningApplicationName: "Verified App")
            ),
            node(
                path: "/Users/test/Library/Application Support/rootfs.img",
                logical: 3_000_000,
                allocated: 30,
                itemType: .regularFile,
                metadata: StorageAnalysisMetadata(isUnusuallyLarge: true)
            ),
            node(
                path: issue.path,
                allocated: 5,
                accessibility: .inaccessible,
                issues: [issue]
            ),
        ]
        let root = node(
            path: "/Users/test/Library/Application Support",
            logical: 3_000_035,
            allocated: 65,
            children: children
        )
        let now = Date(timeIntervalSince1970: 1)
        return StorageAnalysisResult(
            root: root,
            startedAt: now,
            completedAt: now,
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: [issue]
        )
    }

    nonisolated static func node(
        path: String,
        logical: Int64? = nil,
        allocated: Int64,
        itemType: StorageItemType = .directory,
        accessibility: StorageAccessibility = .accessible,
        issues: [StorageScanIssue] = [],
        children: [StorageNode] = [],
        metadata: StorageAnalysisMetadata = StorageAnalysisMetadata()
    ) -> StorageNode {
        StorageNode(
            name: URL(fileURLWithPath: path).lastPathComponent,
            absolutePath: path,
            logicalSize: logical ?? allocated,
            allocatedSize: allocated,
            ownLogicalSize: logical ?? allocated,
            ownAllocatedSize: allocated,
            itemType: itemType,
            children: children,
            accessibility: accessibility,
            scanIssues: issues,
            isHidden: URL(fileURLWithPath: path).lastPathComponent.hasPrefix("."),
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: metadata
        )
    }

    nonisolated static func dockerReport(
        runtimeBytes: Int64,
        location: DockerRuntimeLocation
    ) -> DockerStorageReport {
        let host = StorageAnalysisResult(
            root: node(path: "/Users/test/Docker.raw", logical: 64_000, allocated: 15),
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 1),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )
        let usage = DockerRuntimeStorageUsage(
            category: .images,
            totalBytes: runtimeBytes,
            reclaimableBytes: nil,
            reclaimablePercentage: nil,
            objectCount: 2,
            activeCount: 1
        )
        let relationship: DockerHostRuntimeRelationship = location == .remote
            ? .remoteRuntimeNotRelatedToHostFootprint
            : .localRuntimeMayExplainHostFootprint
        return DockerStorageReport(
            hostFootprint: DockerHostFootprint(
                locations: [host],
                logicalSize: 64_000,
                allocatedSize: 15
            ),
            virtualDisks: [],
            runtimeStatus: .installedAndReachable,
            runtimeAccounting: DockerRuntimeAccounting(
                images: usage,
                containers: nil,
                localVolumes: nil,
                buildCache: nil
            ),
            dockerExecutablePath: nil,
            runtimeContext: DockerRuntimeContext(
                name: location == .remote ? "remote" : "desktop-linux",
                sanitizedEndpoint: location == .remote ? "ssh://remote" : "unix:///local.sock",
                location: location
            ),
            hostRuntimeRelationship: relationship,
            accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
            wasCancelled: false,
            issues: []
        )
    }

    nonisolated static func apfsReport(snapshotSize: Int64?) -> APFSStorageReport {
        let sizeKnowledge: APFSSnapshotSizeKnowledge = snapshotSize == nil
            ? .unavailable
            : .reportedBySystem
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
                    totalCapacity: 1_000,
                    availableCapacity: 200,
                    usedCapacity: 800,
                    availableCapacityForImportantUsage: 300,
                    availableCapacityForOpportunisticUsage: nil,
                    purgeableEstimate: 100,
                    purgeableEstimateKnowledge: .estimated
                )
            ),
            snapshots: [APFSSnapshotInformation(
                identifier: "snapshot-1",
                name: "com.apple.TimeMachine.2026-01-01",
                uuid: nil,
                creationDate: nil,
                size: snapshotSize,
                sizeKnowledge: sizeKnowledge,
                type: .timeMachine,
                source: .diskutil,
                storageRelationship: snapshotSize == nil ? .sizeUnavailable : .sharedNonAdditive
            )],
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )
    }
}

private actor ReportSequence {
    private var reports: [StorageReconciliationReport]

    init(_ reports: [StorageReconciliationReport]) {
        self.reports = reports
    }

    func next() -> StorageReconciliationReport {
        reports.removeFirst()
    }
}
