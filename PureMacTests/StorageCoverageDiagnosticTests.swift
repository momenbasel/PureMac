import Darwin
import XCTest
@testable import PureMac

final class StorageCoverageDiagnosticTests: XCTestCase {
    func testPermissionDeniedAggregation() {
        let issues = [
            issue("/private/a", .permissionDenied, EACCES),
            issue("/private/b", .permissionDenied, EPERM),
        ]
        let value = diagnostic(applicationIssues: issues)

        XCTAssertEqual(value.permissionDeniedIssueCount, 2)
        XCTAssertEqual(categoryCount(.permissionDenied, in: value), 2)
    }

    func testEACCESClassification() {
        XCTAssertEqual(
            StorageCoverageDiagnosticBuilder.category(for: issue("/a", .unreadable, EACCES)),
            .permissionDenied
        )
    }

    func testEPERMClassification() {
        XCTAssertEqual(
            StorageCoverageDiagnosticBuilder.category(for: issue("/a", .metadataUnavailable, EPERM)),
            .permissionDenied
        )
    }

    func testENOENTIsNotPermissionDenied() {
        let value = diagnostic(applicationIssues: [
            issue("/gone", .metadataUnavailable, ENOENT),
        ])

        XCTAssertEqual(value.permissionDeniedIssueCount, 0)
        XCTAssertEqual(categoryCount(.concurrentFilesystemChange, in: value), 1)
    }

    func testDifferentVolumeClassification() {
        let value = diagnostic(applicationIssues: [issue("/mounted", .differentVolume)])

        XCTAssertEqual(categoryCount(.differentVolumeBoundary, in: value), 1)
    }

    func testCancellationClassification() {
        let value = diagnostic(
            applicationIssues: [issue("/cancelled", .cancelled)],
            wasCancelled: true
        )

        XCTAssertEqual(categoryCount(.cancelled, in: value), 1)
    }

    func testFailedAnalyzerClassification() {
        let value = diagnostic(analysisIssues: [
            StorageReconciliationIssue(
                kind: .analyzerFailure,
                stage: .containers,
                path: nil,
                message: "Synthetic failure"
            ),
        ])

        XCTAssertEqual(categoryCount(.failedAnalyzer, in: value), 1)
    }

    func testMissingOptionalRootClassification() {
        let value = diagnostic(coverage: [
            Self.coverage(.opt, "/opt", .missingOptional),
        ])

        XCTAssertEqual(categoryCount(.missingOptionalRoot, in: value), 1)
        XCTAssertTrue(value.coverageGaps.contains { $0.category == .missingOptionalRoot })
    }

    func testUnknownIssueFallback() {
        let value = diagnostic(analysisIssues: [
            StorageReconciliationIssue(
                kind: .analyzerIssue,
                stage: .containers,
                path: "/unknown",
                message: "No structured cause"
            ),
        ])

        XCTAssertEqual(categoryCount(.unknown, in: value), 1)
    }

    func testIssueCountsByAnalyzer() {
        let value = diagnostic(
            applicationIssues: [issue("/app/a", .unreadable)],
            privateIssues: [issue("/private/a", .metadataUnavailable)]
        )

        XCTAssertEqual(analyzerCount(.applicationSupport, in: value), 1)
        XCTAssertEqual(analyzerCount(.privateStorage, in: value), 1)
    }

    func testIssueCountsByErrno() {
        let value = diagnostic(applicationIssues: [
            issue("/a", .permissionDenied, EACCES),
            issue("/b", .permissionDenied, EACCES),
            issue("/c", .permissionDenied, EPERM),
        ])

        XCTAssertEqual(value.measurementIssues.errnoCounts.first { $0.errorCode == EACCES }?.count, 2)
        XCTAssertEqual(value.measurementIssues.errnoCounts.first { $0.errorCode == EPERM }?.count, 1)
    }

    func testParentPathAggregation() {
        let value = diagnostic(applicationIssues: [
            issue("/private/db/a", .unreadable),
            issue("/private/db/b", .unreadable),
            issue("/private/other/c", .unreadable),
        ])

        XCTAssertEqual(value.measurementIssues.topAffectedParentPaths.first?.parentPath, "/private/db")
        XCTAssertEqual(value.measurementIssues.topAffectedParentPaths.first?.count, 2)
    }

    func testRepresentativePathLimiting() {
        let issues = (0..<12).map { issue("/root/item\($0)", .unreadable) }
        let value = diagnostic(applicationIssues: issues, representativePathLimit: 3)

        XCTAssertEqual(value.measurementIssues.groups.first?.count, 12)
        XCTAssertEqual(value.measurementIssues.groups.first?.representativePaths.count, 3)
    }

    @MainActor
    func testFullDiskAccessGrantedWithoutPermissionErrorsDoesNotRecommendFDA() async {
        let state = StorageIntelligenceState(analysisRunner: { _ in
            Self.report(diagnostic: .empty)
        })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertNil(state.permissionGuidance(fullDiskAccessGranted: true))
    }

    @MainActor
    func testFullDiskAccessGrantedWithPermissionErrorsExposesEvidenceBasedGuidance() async {
        let value = diagnostic(applicationIssues: [issue("/private/denied", .permissionDenied, EACCES)])
        let state = StorageIntelligenceState(analysisRunner: { _ in Self.report(diagnostic: value) })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(
            state.permissionGuidance(fullDiskAccessGranted: true)?.kind,
            .permissionDenialsRemainWithFullDiskAccess
        )
    }

    func testHiddenHomeCoverageGapDetection() throws {
        let home = try makeHomeFixture()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cache"),
            withIntermediateDirectories: false
        )

        let result = StorageCoverageGapDiscovery.discoverSynchronously(homeDirectoryURL: home)

        XCTAssertEqual(result.hiddenHomeEntries.map(\.name), [".cache"])
        XCTAssertTrue(result.hiddenHomeEntries.allSatisfy { $0.confidence == .unmeasured })
    }

    func testUnspecializedLibraryCoverageGapDetection() throws {
        let home = try makeHomeFixture()
        let library = home.appendingPathComponent("Library")
        for name in ["Caches", "Mail", "Messages"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }

        let result = StorageCoverageGapDiscovery.discoverSynchronously(homeDirectoryURL: home)

        XCTAssertEqual(result.unspecializedLibraryEntries.map(\.name), ["Caches", "Mail", "Messages"])
    }

    func testSpecializedLibraryRootsAreNotReportedAsUncovered() throws {
        let home = try makeHomeFixture()
        let library = home.appendingPathComponent("Library")
        for name in ["Application Support", "Containers", "Group Containers"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }

        let result = StorageCoverageGapDiscovery.discoverSynchronously(homeDirectoryURL: home)

        XCTAssertTrue(result.unspecializedLibraryEntries.isEmpty)
    }

    func testAPFSSnapshotsRemainNonAdditive() {
        let value = diagnostic(apfs: apfsReport(purgeable: nil, snapshotSize: 500))

        XCTAssertTrue(value.coverageMap.contains {
            $0.state == .nonAdditive && $0.confidence == .nonAdditiveMetadata
        })
        XCTAssertTrue(value.unexplainedSpaceExplanations.contains {
            $0.category == .nonAdditiveAPFSStorage
        })
    }

    func testPurgeableRemainsNonAdditive() {
        let value = diagnostic(apfs: apfsReport(purgeable: 250), purgeable: 250)

        XCTAssertTrue(value.unexplainedSpaceExplanations.contains {
            $0.title == "Purgeable capacity is an estimate"
        })
        XCTAssertFalse(value.coverageMap.contains { $0.identifier.contains("purgeable:250") })
    }

    @MainActor
    func testExplainedBytesAreUnchangedByDiagnosticPreparation() async {
        let original: Int64 = 118_520
        let report = Self.report(explained: original, diagnostic: diagnostic())
        let state = StorageIntelligenceState(analysisRunner: { _ in report })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.explainedAllocatedBytes, original)
    }

    @MainActor
    func testUnexplainedBytesAreUnchangedByDiagnosticPreparation() async {
        let original: Int64 = 98_240
        let report = Self.report(unexplained: original, diagnostic: diagnostic())
        let state = StorageIntelligenceState(analysisRunner: { _ in report })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.unexplainedBytes, original)
    }

    func testDiagnosticsNeverFabricateInaccessibleByteCounts() {
        let value = diagnostic(applicationIssues: [issue("/private/unknown-size", .unreadable)])
        let gap = value.coverageGaps[0]

        XCTAssertNil(gap.allocatedBytes)
        XCTAssertNil(gap.logicalBytes)
        XCTAssertEqual(gap.confidence, .knownLowerBound)
    }

    func testPartialAnalyzerResultIsKnownLowerBound() {
        let value = diagnostic(coverage: [
            Self.coverage(.applicationSupport, "/Users/test/Library/Application Support", .partiallyCompleted),
        ])

        XCTAssertEqual(
            value.analyzerStatuses.first { $0.analyzer == .applicationSupport }?.confidence,
            .knownLowerBound
        )
    }

    func testCompleteAnalyzerResultIsComplete() {
        let value = diagnostic(coverage: [
            Self.coverage(.applicationSupport, "/Users/test/Library/Application Support", .completed),
        ])

        XCTAssertEqual(
            value.analyzerStatuses.first { $0.analyzer == .applicationSupport }?.confidence,
            .completeMeasurement
        )
    }

    func testCancellationProducesPartialDiagnosticResults() {
        let value = diagnostic(
            applicationIssues: [issue("/measured/before-cancel", .unreadable)],
            wasCancelled: true
        )

        XCTAssertEqual(categoryCount(.inaccessible, in: value), 1)
        XCTAssertEqual(categoryCount(.cancelled, in: value), 1)
        XCTAssertEqual(value.explainedStorageConfidence, .knownLowerBound)
    }

    func testDiagnosticPreparationDoesNotMutateAnalyzerResults() {
        let before = analyzerResults(applicationIssues: [issue("/a", .unreadable)])
        _ = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: before,
            canonicalRootCoverage: Self.defaultCoverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 10,
            purgeableEstimateBytes: nil,
            incompleteCoverage: true,
            wasCancelled: false
        )

        XCTAssertEqual(before, analyzerResults(applicationIssues: [issue("/a", .unreadable)]))
    }

    @MainActor
    func testNoCleanupActionIsExposed() {
        let actions = StorageIntelligenceState().availableActions.map(\.rawValue)

        XCTAssertFalse(actions.contains(where: {
            $0.localizedCaseInsensitiveContains("clean")
                || $0.localizedCaseInsensitiveContains("delete")
                || $0.localizedCaseInsensitiveContains("trash")
        }))
    }

    func testLargeIssueCollectionsAggregateCorrectly() {
        let issues = (0..<1_000).map { issue("/large/entry-\($0)", .unreadable) }
        let value = diagnostic(applicationIssues: issues)

        XCTAssertEqual(value.measurementIssues.totalIssueCount, 1_000)
        XCTAssertEqual(categoryCount(.inaccessible, in: value), 1_000)
        XCTAssertLessThanOrEqual(value.measurementIssues.groups.first?.representativePaths.count ?? 0, 5)
    }

    @MainActor
    func testStateHandlesZeroIssues() async {
        let state = StorageIntelligenceState(analysisRunner: { _ in Self.report(diagnostic: .empty) })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.coverage?.measurementIssueCount, 0)
        XCTAssertEqual(state.lifecycle, .completed)
    }

    @MainActor
    func testStateHandlesHundredsOfIssues() async {
        let issues = (0..<401).map { issue("/realistic/entry-\($0)", .unreadable) }
        let value = diagnostic(applicationIssues: issues)
        let state = StorageIntelligenceState(analysisRunner: { _ in Self.report(diagnostic: value) })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.coverage?.measurementIssueCount, 401)
        XCTAssertEqual(state.coverageDiagnostic?.measurementIssues.groups.count, 1)
    }

    @MainActor
    func testSearchAndDiagnosticDrillDownDoNotTriggerRescanning() async {
        let counter = CallCounter()
        let value = diagnostic()
        let state = StorageIntelligenceState(analysisRunner: { _ in
            await counter.increment()
            return Self.report(diagnostic: value)
        })
        state.analyze()
        await state.waitForAnalysis()
        state.showDiagnostics()
        state.updateSearch("cache")
        await state.waitForSearch()

        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(state.isShowingDiagnostics)
    }

    func testDiagnosticOrderingIsDeterministic() {
        let issues = [
            issue("/z", .unreadable),
            issue("/a", .metadataUnavailable),
            issue("/m", .permissionDenied, EACCES),
        ]

        XCTAssertEqual(
            diagnostic(applicationIssues: issues),
            diagnostic(applicationIssues: Array(issues.reversed()))
        )
    }

    func testDuplicateIssuePathsAreAggregatedSafely() {
        let duplicate = issue("/same/path", .permissionDenied, EACCES)
        let value = diagnostic(applicationIssues: [duplicate, duplicate, duplicate])

        XCTAssertEqual(value.measurementIssues.totalIssueCount, 1)
        XCTAssertEqual(value.permissionDeniedIssueCount, 1)
    }

    @MainActor
    func testExistingStorageIntelligencePresentationRemainsCompatible() async {
        let state = StorageIntelligenceState(analysisRunner: { _ in
            Self.report(explained: 65, unexplained: 735, diagnostic: .empty)
        })
        state.analyze()
        await state.waitForAnalysis()

        XCTAssertEqual(state.summary?.explainedAllocatedBytes, 65)
        XCTAssertEqual(state.summary?.unexplainedBytes, 735)
        XCTAssertTrue(state.availableActions.contains(.analyze))
        XCTAssertTrue(state.availableActions.contains(.viewDiagnostics))
    }
}

private extension StorageCoverageDiagnosticTests {
    actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    static let defaultCoverage = [
        StorageCanonicalRootCoverage(
            root: .applicationSupport,
            configuredPath: "/Users/test/Library/Application Support",
            state: .completed,
            knownAllocatedBytes: 10,
            unreadablePathCount: 0
        ),
    ]

    func issue(
        _ path: String,
        _ kind: StorageScanIssueKind,
        _ errorCode: Int32? = nil
    ) -> StorageScanIssue {
        StorageScanIssue(
            path: path,
            kind: kind,
            message: "Synthetic \(kind.rawValue)",
            posixErrorCode: errorCode
        )
    }

    static func coverage(
        _ root: StorageCanonicalRoot,
        _ path: String,
        _ state: StorageCanonicalRootState
    ) -> StorageCanonicalRootCoverage {
        StorageCanonicalRootCoverage(
            root: root,
            configuredPath: path,
            state: state,
            knownAllocatedBytes: state == .missingOptional ? 0 : 10,
            unreadablePathCount: state == .partiallyCompleted ? 1 : 0
        )
    }

    func diagnostic(
        applicationIssues: [StorageScanIssue] = [],
        privateIssues: [StorageScanIssue] = [],
        coverage: [StorageCanonicalRootCoverage]? = nil,
        analysisIssues: [StorageReconciliationIssue] = [],
        apfs: APFSStorageReport? = nil,
        purgeable: Int64? = nil,
        wasCancelled: Bool = false,
        representativePathLimit: Int = 5
    ) -> StorageCoverageDiagnostic {
        StorageCoverageDiagnosticBuilder(
            representativePathLimit: representativePathLimit
        ).build(
            analyzerResults: analyzerResults(
                applicationIssues: applicationIssues,
                privateIssues: privateIssues,
                apfs: apfs
            ),
            canonicalRootCoverage: coverage ?? Self.defaultCoverage,
            filesystemContributions: [],
            analysisIssues: analysisIssues,
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 100,
            purgeableEstimateBytes: purgeable,
            incompleteCoverage: true,
            wasCancelled: wasCancelled
        )
    }

    func analyzerResults(
        applicationIssues: [StorageScanIssue] = [],
        privateIssues: [StorageScanIssue] = [],
        apfs: APFSStorageReport? = nil
    ) -> StorageAnalyzerResults {
        StorageAnalyzerResults(
            userHomeStorage: nil,
            applicationSupport: result(
                path: "/Users/test/Library/Application Support",
                issues: applicationIssues
            ),
            containers: nil,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: privateIssues.isEmpty ? nil : result(path: "/private", issues: privateIssues),
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: apfs
        )
    }

    func result(path: String, issues: [StorageScanIssue]) -> StorageAnalysisResult {
        let accessibility: StorageAccessibility = issues.isEmpty ? .accessible : .partiallyAccessible
        let node = StorageNode(
            name: URL(fileURLWithPath: path).lastPathComponent,
            absolutePath: path,
            logicalSize: 10,
            allocatedSize: 10,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .directory,
            children: [],
            accessibility: accessibility,
            scanIssues: issues,
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )
        return StorageAnalysisResult(
            root: node,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            rootDeviceIdentifier: 1,
            wasCancelled: issues.contains { $0.kind == .cancelled },
            issues: issues
        )
    }

    func apfsReport(
        purgeable: Int64?,
        snapshotSize: Int64? = nil
    ) -> APFSStorageReport {
        let snapshot = APFSSnapshotInformation(
            identifier: "snapshot",
            name: "com.apple.TimeMachine.2026-01-01-000000.local",
            uuid: "UUID",
            creationDate: Date(timeIntervalSince1970: 3),
            size: snapshotSize,
            sizeKnowledge: snapshotSize == nil ? .unavailable : .reportedBySystem,
            type: .timeMachine,
            source: .diskutil,
            storageRelationship: snapshotSize == nil ? .sizeUnavailable : .sharedNonAdditive
        )
        return APFSStorageReport(
            volume: APFSVolumeInformation(
                name: "Data",
                volumeIdentifier: "disk3s1",
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
                    availableCapacityForImportantUsage: purgeable.map { 200 + $0 },
                    availableCapacityForOpportunisticUsage: nil,
                    purgeableEstimate: purgeable,
                    purgeableEstimateKnowledge: purgeable == nil ? .unavailable : .estimated
                )
            ),
            snapshots: [snapshot],
            state: .complete,
            accountingRelationship: .volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees,
            wasCancelled: false,
            issues: []
        )
    }

    func categoryCount(
        _ category: StorageCoverageDiagnosticCategory,
        in diagnostic: StorageCoverageDiagnostic
    ) -> Int {
        diagnostic.measurementIssues.categoryCounts.first { $0.category == category }?.count ?? 0
    }

    func analyzerCount(
        _ analyzer: StorageAnalyzerStage,
        in diagnostic: StorageCoverageDiagnostic
    ) -> Int {
        diagnostic.measurementIssues.analyzerCounts.first { $0.analyzer == analyzer }?.count ?? 0
    }

    func makeHomeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCoverageDiagnosticTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library"),
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    static func report(
        explained: Int64 = 65,
        unexplained: Int64? = 735,
        diagnostic: StorageCoverageDiagnostic
    ) -> StorageReconciliationReport {
        let now = Date(timeIntervalSince1970: 1)
        return StorageReconciliationReport(
            totalCapacityBytes: 1_000,
            usedCapacityBytes: 800,
            availableCapacityBytes: 200,
            purgeableEstimateBytes: 100,
            explainedAllocatedBytes: explained,
            unexplainedBytes: unexplained,
            inaccessibleKnownLowerBoundBytes: 0,
            unreadablePathCount: diagnostic.measurementIssues.totalIssueCount,
            incompleteCoverage: true,
            coverageStatus: diagnostic.permissionDeniedIssueCount > 0
                ? .partialDueToPermissions
                : diagnostic.measurementIssues.totalIssueCount > 0
                    ? .partialDueToMeasurementIssues
                    : .completeForConfiguredRoots,
            canonicalRootCoverage: [],
            filesystemContributions: [],
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: [],
            analyzerResults: StorageAnalyzerResults(
                userHomeStorage: nil,
                applicationSupport: nil,
                containers: nil,
                groupContainers: nil,
                systemLibrary: nil,
                privateStorage: nil,
                dataVolumeHiddenStorage: nil,
                developerSystemStorage: nil,
                dockerStorage: nil,
                apfsStorage: nil
            ),
            coverageDiagnostic: diagnostic,
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
}
