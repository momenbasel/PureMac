import XCTest
@testable import PureMac

final class StorageAnalysisCoordinatorTests: XCTestCase {
    func testSuccessfulMultiAnalyzerReconciliation() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.coverageStatus, .completeForConfiguredRoots)
        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(report.progress.completedStages, 12)
    }

    func testExplainedBytesUseCanonicalAllocatedTotals() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testUnexplainedBytesAreUsedMinusExplained() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.usedCapacityBytes, 1_000)
        XCTAssertEqual(report.unexplainedBytes, 640)
    }

    func testUnexplainedBytesNeverBecomeNegative() async {
        var inputs = Inputs.baseline
        inputs.apfs = Self.apfsReport(used: 100)

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.unexplainedBytes, 0)
    }

    func testDockerHostInsideContainersIsNotDoubleCounted() async {
        let report = await Self.makeCoordinator().analyze()
        let docker = Self.contribution(report, source: .dockerHostOutsideCanonicalRoots)

        XCTAssertEqual(docker?.accountedAllocatedBytes, 0)
        XCTAssertEqual(docker?.owningPath, "/Users/test/Library/Containers")
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testDockerRuntimeAccountingIsNonAdditive() async {
        var inputs = Inputs.baseline
        inputs.docker = Self.dockerReport(
            hostLocations: [],
            runtimeBytes: 50_000,
            runtimeLocation: .local
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.analyzerResults.dockerStorage?.totalRuntimeReportedBytes, 50_000)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testRemoteDockerRuntimeRemainsUnrelatedAndNonAdditive() async {
        var inputs = Inputs.baseline
        inputs.docker = Self.dockerReport(
            hostLocations: [],
            runtimeBytes: 90_000,
            runtimeLocation: .remote
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(
            report.analyzerResults.dockerStorage?.hostRuntimeRelationship,
            .remoteRuntimeNotRelatedToHostFootprint
        )
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testAPFSSnapshotsAreNonAdditive() async {
        var inputs = Inputs.baseline
        inputs.apfs = Self.apfsReport(used: 1_000, snapshotSize: 700)

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.analyzerResults.apfsStorage?.snapshots.first?.size, 700)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
        XCTAssertEqual(report.unexplainedBytes, 640)
    }

    func testPurgeableEstimateRemainsSeparate() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.purgeableEstimateBytes, 100)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
        XCTAssertEqual(report.unexplainedBytes, 640)
    }

    func testNestedCanonicalPathIsExcluded() async {
        var inputs = Inputs.baseline
        inputs.applicationSupport = Self.result(path: "/Users/test/Library", allocated: 100)
        inputs.containers = Self.result(path: "/Users/test/Library/Containers", allocated: 20)

        let report = await Self.makeCoordinator(inputs).analyze()
        let containers = Self.contribution(report, source: .containers)

        XCTAssertEqual(containers?.relationship, .excludedNestedPath)
        XCTAssertEqual(containers?.accountedAllocatedBytes, 0)
    }

    func testDuplicateCanonicalRootIsCountedOnce() async {
        var inputs = Inputs.baseline
        inputs.applicationSupport = Self.result(path: "/same", allocated: 10)
        inputs.containers = Self.result(path: "/same", allocated: 20)

        let report = await Self.makeCoordinator(inputs).analyze()
        let duplicate = Self.contribution(report, source: .containers)

        XCTAssertEqual(duplicate?.relationship, .excludedDuplicatePath)
        XCTAssertTrue(report.analysisIssues.contains { $0.kind == .duplicateRootExcluded })
    }

    func testMissingOptionalDeveloperRootDoesNotFailCoverage() async {
        var inputs = Inputs.baseline
        inputs.developer = Self.developerReport(optState: .missing, optSize: 0)

        let report = await Self.makeCoordinator(inputs).analyze()
        let opt = report.canonicalRootCoverage.first { $0.root == .opt }

        XCTAssertEqual(opt?.state, .missingOptional)
        XCTAssertEqual(report.coverageStatus, .completeForConfiguredRoots)
    }

    func testAnalyzerFailureReturnsPartialReport() async {
        let report = await Self.makeCoordinator(.baseline, failing: .systemLibrary).analyze()

        XCTAssertNil(report.analyzerResults.systemLibrary)
        XCTAssertNotNil(report.analyzerResults.containers)
        XCTAssertEqual(report.coverageStatus, .partialDueToAnalyzerFailure)
        XCTAssertTrue(report.analysisIssues.contains { $0.kind == .analyzerFailure })
    }

    func testPermissionIncompleteAnalyzerReportsKnownLowerBound() async {
        var inputs = Inputs.baseline
        let issue = StorageScanIssue(
            path: "/private/secret",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )
        inputs.privateStorage = Self.result(
            path: "/private",
            allocated: 50,
            accessibility: .partiallyAccessible,
            issues: [issue]
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.coverageStatus, .partialDueToPermissions)
        XCTAssertEqual(report.inaccessibleKnownLowerBoundBytes, 50)
        XCTAssertEqual(report.unreadablePathCount, 1)
    }

    func testCancelledAnalyzerProducesCancelledCoverage() async {
        var inputs = Inputs.baseline
        inputs.containers = Self.result(
            path: "/Users/test/Library/Containers",
            allocated: 12,
            accessibility: .cancelled,
            wasCancelled: true
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.coverageStatus, .partialDueToCancellation)
        XCTAssertEqual(report.progress.state, .cancelled)
    }

    func testGlobalCancellationStopsSchedulingAndReturnsPartialReport() async {
        let coordinator = Self.delayedCoordinator()
        let task = Task { await coordinator.analyze() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.coverageStatus, .partialDueToCancellation)
        XCTAssertLessThan(report.progress.completedStages, report.progress.totalStages)
    }

    func testCoverageStatusIsCompleteOnlyForConfiguredRoots() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.coverageStatus, .completeForConfiguredRoots)
        XCTAssertTrue(report.incompleteCoverage)
        XCTAssertEqual(report.canonicalRootCoverage.count, 11)
    }

    func testIssuesAreAggregatedFromAnalyzerResults() async {
        var inputs = Inputs.baseline
        let issue = StorageScanIssue(
            path: "/Library/broken",
            kind: .unreadable,
            message: "Unreadable entry.",
            posixErrorCode: EIO
        )
        inputs.systemLibrary = Self.result(
            path: "/Library",
            allocated: 40,
            accessibility: .partiallyAccessible,
            issues: [issue]
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertTrue(report.analysisIssues.contains {
            $0.stage == .systemLibrary && $0.path == "/Library/broken"
        })
    }

    func testProgressAccountsForEveryStage() async {
        let recorder = ProgressRecorder()
        let report = await Self.makeCoordinator().analyze { progress in
            await recorder.append(progress)
        }
        let values = await recorder.values

        XCTAssertEqual(values.first?.totalStages, 12)
        XCTAssertEqual(values.last?.completedStages, 12)
        XCTAssertEqual(values.last?.runningStages, [])
        XCTAssertEqual(report.progress, values.last)
    }

    func testZeroUsedSpaceProducesZeroUnexplainedBytes() async {
        var inputs = Inputs.baseline
        inputs.apfs = Self.apfsReport(used: 0)

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.unexplainedBytes, 0)
    }

    func testUsedCapacityGreaterThanExplainedRetainsRemainder() async {
        var inputs = Inputs.baseline
        inputs.apfs = Self.apfsReport(used: 10_000)

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.unexplainedBytes, 9_640)
    }

    func testExplainedGreaterThanUsedIsClampedAndReported() async {
        var inputs = Inputs.baseline
        inputs.apfs = Self.apfsReport(used: 100)

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.unexplainedBytes, 0)
        XCTAssertTrue(report.analysisIssues.contains { $0.kind == .accountingAnomaly })
    }

    func testHiddenDataVolumeChildrenDoNotDuplicateLibraryOrPrivate() async {
        var inputs = Inputs.baseline
        inputs.hidden = Self.result(
            path: "/System/Volumes/Data",
            allocated: 22,
            children: [
                Self.node(path: "/Library/.hidden", allocated: 11, hidden: true),
                Self.node(path: "/private/.hidden", allocated: 11, hidden: true),
            ]
        )

        let report = await Self.makeCoordinator(inputs).analyze()
        let hidden = report.filesystemContributions.filter {
            $0.source == .dataVolumeHiddenStorage
        }

        XCTAssertEqual(hidden.count, 2)
        XCTAssertTrue(hidden.allSatisfy { $0.accountedAllocatedBytes == 0 })
    }

    func testOptAndUsrLocalRemainSeparateContributionsWithSharedLedgerTotal() async {
        let report = await Self.makeCoordinator().analyze()
        let opt = Self.contribution(report, source: .opt)
        let usrLocal = Self.contribution(report, source: .usrLocal)

        XCTAssertEqual(opt?.observedAllocatedBytes, 70)
        XCTAssertEqual(usrLocal?.observedAllocatedBytes, 80)
        XCTAssertEqual((opt?.accountedAllocatedBytes ?? 0) + (usrLocal?.accountedAllocatedBytes ?? 0), 150)
    }

    func testApplicationAttributionMetadataDoesNotAddBytes() async {
        var inputs = Inputs.baseline
        inputs.applicationSupport = Self.result(
            path: "/Users/test/Library/Application Support",
            allocated: 10,
            metadata: StorageAnalysisMetadata(
                owningApplicationIdentifier: "com.example.large",
                owningApplicationName: "Large App",
                attributes: ["reportedSize": "999999"]
            )
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testSparseLogicalCapacityDoesNotAffectExplainedAllocatedBytes() async {
        var inputs = Inputs.baseline
        inputs.applicationSupport = Self.result(
            path: "/Users/test/Library/Application Support",
            logical: 1_000_000,
            allocated: 10
        )

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testCrossAnalyzerHardLinkLimitationIsExplicit() async {
        let report = await Self.makeCoordinator().analyze()

        XCTAssertEqual(report.hardLinkAccountingStatus, .deduplicatedWithinAnalyzerScopesOnly)
        XCTAssertTrue(report.analysisIssues.contains {
            $0.kind == .crossAnalyzerHardLinkDeduplicationUnavailable
        })
    }

    func testReportOrderingIsDeterministic() async {
        let first = await Self.makeCoordinator().analyze()
        let second = await Self.makeCoordinator().analyze()

        XCTAssertEqual(first.filesystemContributions, second.filesystemContributions)
        XCTAssertEqual(first.canonicalRootCoverage, second.canonicalRootCoverage)
        XCTAssertEqual(first.analysisIssues, second.analysisIssues)
    }

    func testCoordinatorSourceReferencesNoCleanupOrDeletionAPIs() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PureMac/Services/StorageAnalysisCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in ["CleaningEngine", "removeItem(", "trashItem(", "purgePurgeable", "deleteSnapshot"] {
            XCTAssertFalse(source.contains(forbidden), "Unexpected mutating API reference: \(forbidden)")
        }
    }

    func testAllExistingAnalyzerResultsRemainAccessible() async {
        let results = await Self.makeCoordinator().analyze().analyzerResults

        XCTAssertNotNil(results.userHomeStorage)
        XCTAssertNotNil(results.applications)
        XCTAssertNotNil(results.applicationSupport)
        XCTAssertNotNil(results.containers)
        XCTAssertNotNil(results.groupContainers)
        XCTAssertNotNil(results.systemLibrary)
        XCTAssertNotNil(results.privateStorage)
        XCTAssertNotNil(results.dataVolumeHiddenStorage)
        XCTAssertNotNil(results.developerSystemStorage)
        XCTAssertNotNil(results.dockerStorage)
        XCTAssertNotNil(results.apfsStorage)
        XCTAssertNotNil(results.coverageExpansion)
    }

    func testCoordinatorIncludesApplicationsBytes() async {
        var inputs = Inputs.baseline
        inputs.applications = Self.result(path: "/Applications", allocated: 150)

        let report = await Self.makeCoordinator(inputs).analyze()
        let contribution = Self.contribution(report, source: .applications)

        XCTAssertEqual(contribution?.accountedAllocatedBytes, 150)
        XCTAssertEqual(report.explainedAllocatedBytes, 510)
    }

    func testApplicationsDeduplicatedWithDataVolumeApplications() async {
        var inputs = Inputs.baseline
        inputs.applications = Self.result(path: "/Applications", allocated: 200)

        let report = await Self.makeCoordinator(inputs).analyze()
        let contributions = report.filesystemContributions.filter { $0.source == .applications }

        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(contributions.first?.accountedAllocatedBytes, 200)
    }

    func testCoordinatorIncludesVisibleUserHomeBytes() async {
        var inputs = Inputs.baseline
        inputs.userHome = Self.userHomeReport(roots: [
            ("/Users/test/Documents", 100),
            ("/Users/test/Downloads", 25),
        ])

        let report = await Self.makeCoordinator(inputs).analyze()
        let contributions = report.filesystemContributions.filter {
            $0.source == .userHomeVisibleStorage
        }

        XCTAssertEqual(contributions.reduce(0) { $0 + $1.accountedAllocatedBytes }, 125)
        XCTAssertEqual(report.explainedAllocatedBytes, 485)
    }

    func testUserHomeCannotOverlapApplicationSupport() async {
        var inputs = Inputs.baseline
        inputs.userHome = Self.userHomeReport(roots: [
            ("/Users/test/Library/Application Support", 900),
        ])

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(Self.contribution(report, source: .applicationSupport)?.accountedAllocatedBytes, 10)
        XCTAssertEqual(Self.contribution(report, source: .userHomeVisibleStorage)?.accountedAllocatedBytes, 0)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testUserHomeCannotOverlapContainers() async {
        var inputs = Inputs.baseline
        inputs.userHome = Self.userHomeReport(roots: [
            ("/Users/test/Library/Containers", 900),
        ])

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(Self.contribution(report, source: .containers)?.accountedAllocatedBytes, 20)
        XCTAssertEqual(Self.contribution(report, source: .userHomeVisibleStorage)?.accountedAllocatedBytes, 0)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testUserHomeCannotOverlapGroupContainers() async {
        var inputs = Inputs.baseline
        inputs.userHome = Self.userHomeReport(roots: [
            ("/Users/test/Library/Group Containers", 900),
        ])

        let report = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(Self.contribution(report, source: .groupContainers)?.accountedAllocatedBytes, 30)
        XCTAssertEqual(Self.contribution(report, source: .userHomeVisibleStorage)?.accountedAllocatedBytes, 0)
        XCTAssertEqual(report.explainedAllocatedBytes, 360)
    }

    func testUserHomeBytesReduceUnexplainedCapacityExactlyOnce() async {
        let baseline = await Self.makeCoordinator().analyze()
        var inputs = Inputs.baseline
        inputs.userHome = Self.userHomeReport(roots: [("/Users/test/Documents", 100)])

        let expanded = await Self.makeCoordinator(inputs).analyze()

        XCTAssertEqual(expanded.explainedAllocatedBytes - baseline.explainedAllocatedBytes, 100)
        XCTAssertEqual((baseline.unexplainedBytes ?? 0) - (expanded.unexplainedBytes ?? 0), 100)
    }
}

// MARK: - Fixtures

private extension StorageAnalysisCoordinatorTests {
    struct TestFailure: Error {}

    struct Inputs: Sendable {
        var userHome: UserHomeStorageReport
        var applications: StorageAnalysisResult
        var applicationSupport: StorageAnalysisResult
        var containers: StorageAnalysisResult
        var groupContainers: StorageAnalysisResult
        var systemLibrary: StorageAnalysisResult
        var privateStorage: StorageAnalysisResult
        var hidden: StorageAnalysisResult
        var developer: DeveloperSystemStorageReport
        var docker: DockerStorageReport
        var apfs: APFSStorageReport
        var coverageExpansion: StorageCoverageExpansionReport

        static var baseline: Inputs {
            Inputs(
                userHome: userHomeReport(),
                applications: result(path: "/Applications", allocated: 0),
                applicationSupport: result(
                    path: "/Users/test/Library/Application Support",
                    allocated: 10
                ),
                containers: result(
                    path: "/Users/test/Library/Containers",
                    allocated: 20
                ),
                groupContainers: result(
                    path: "/Users/test/Library/Group Containers",
                    allocated: 30
                ),
                systemLibrary: result(path: "/Library", allocated: 40),
                privateStorage: result(path: "/private", allocated: 50),
                hidden: result(
                    path: "/System/Volumes/Data",
                    allocated: 60,
                    children: [node(path: "/System/Volumes/Data/.hidden", allocated: 60, hidden: true)]
                ),
                developer: developerReport(),
                docker: dockerReport(hostLocations: [
                    result(
                        path: "/Users/test/Library/Containers/com.docker.docker",
                        allocated: 15
                    ),
                ]),
                apfs: apfsReport(used: 1_000),
                coverageExpansion: .empty
            )
        }
    }

    static func makeCoordinator(
        _ inputs: Inputs = .baseline,
        failing stage: StorageAnalyzerStage? = nil
    ) -> StorageAnalysisCoordinator {
        StorageAnalysisCoordinator(
            userHomeStorageAnalysis: {
                if stage == .userHomeStorage { throw TestFailure() }
                return inputs.userHome
            },
            applicationsAnalysis: {
                if stage == .applications { throw TestFailure() }
                return inputs.applications
            },
            applicationSupportAnalysis: {
                if stage == .applicationSupport { throw TestFailure() }
                return inputs.applicationSupport
            },
            containersAnalysis: {
                if stage == .containers { throw TestFailure() }
                return inputs.containers
            },
            groupContainersAnalysis: {
                if stage == .groupContainers { throw TestFailure() }
                return inputs.groupContainers
            },
            systemLibraryAnalysis: {
                if stage == .systemLibrary { throw TestFailure() }
                return inputs.systemLibrary
            },
            privateStorageAnalysis: {
                if stage == .privateStorage { throw TestFailure() }
                return inputs.privateStorage
            },
            dataVolumeHiddenStorageAnalysis: {
                if stage == .dataVolumeHiddenStorage { throw TestFailure() }
                return inputs.hidden
            },
            developerSystemStorageAnalysis: {
                if stage == .developerSystemStorage { throw TestFailure() }
                return inputs.developer
            },
            dockerStorageAnalysis: {
                if stage == .dockerStorage { throw TestFailure() }
                return inputs.docker
            },
            apfsStorageAnalysis: {
                if stage == .apfsVolume { throw TestFailure() }
                return inputs.apfs
            },
            coverageExpansionAnalysis: {
                if stage == .coverageExpansion { throw TestFailure() }
                return inputs.coverageExpansion
            },
            coverageDiscovery: {
                .empty(homeDirectoryPath: "/Users/test")
            }
        )
    }

    static func delayedCoordinator() -> StorageAnalysisCoordinator {
        let delay: @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let inputs = Inputs.baseline
        return StorageAnalysisCoordinator(
            maxConcurrentAnalyzers: 2,
            userHomeStorageAnalysis: { try await delay(); return inputs.userHome },
            applicationsAnalysis: { try await delay(); return inputs.applications },
            applicationSupportAnalysis: { try await delay(); return inputs.applicationSupport },
            containersAnalysis: { try await delay(); return inputs.containers },
            groupContainersAnalysis: { try await delay(); return inputs.groupContainers },
            systemLibraryAnalysis: { try await delay(); return inputs.systemLibrary },
            privateStorageAnalysis: { try await delay(); return inputs.privateStorage },
            dataVolumeHiddenStorageAnalysis: { try await delay(); return inputs.hidden },
            developerSystemStorageAnalysis: { try await delay(); return inputs.developer },
            dockerStorageAnalysis: { try await delay(); return inputs.docker },
            apfsStorageAnalysis: { try await delay(); return inputs.apfs },
            coverageExpansionAnalysis: { try await delay(); return inputs.coverageExpansion },
            coverageDiscovery: { .empty(homeDirectoryPath: "/Users/test") }
        )
    }

    static func contribution(
        _ report: StorageReconciliationReport,
        source: StorageAccountingSource
    ) -> StorageFilesystemContribution? {
        report.filesystemContributions.first { $0.source == source }
    }

    static func userHomeReport(
        roots: [(path: String, allocated: Int64)] = []
    ) -> UserHomeStorageReport {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let total = roots.reduce(Int64(0)) { $0 + $1.allocated }
        let input = result(
            path: home.path,
            allocated: total,
            children: roots.map { node(path: $0.path, allocated: $0.allocated) }
        )
        return UserHomeStorageAnalyzer.makeReport(
            input,
            homeDirectoryURL: home,
            largeAllocatedSizeThreshold: 1_073_741_824
        )
    }

    static func result(
        path: String,
        logical: Int64? = nil,
        allocated: Int64,
        accessibility: StorageAccessibility = .accessible,
        issues: [StorageScanIssue] = [],
        children: [StorageNode] = [],
        metadata: StorageAnalysisMetadata = StorageAnalysisMetadata(),
        wasCancelled: Bool = false
    ) -> StorageAnalysisResult {
        let date = Date(timeIntervalSince1970: 1)
        return StorageAnalysisResult(
            root: node(
                path: path,
                logical: logical,
                allocated: allocated,
                accessibility: accessibility,
                issues: issues,
                children: children,
                metadata: metadata
            ),
            startedAt: date,
            completedAt: date,
            rootDeviceIdentifier: 1,
            wasCancelled: wasCancelled,
            issues: issues
        )
    }

    static func node(
        path: String,
        logical: Int64? = nil,
        allocated: Int64,
        accessibility: StorageAccessibility = .accessible,
        issues: [StorageScanIssue] = [],
        children: [StorageNode] = [],
        hidden: Bool = false,
        metadata: StorageAnalysisMetadata = StorageAnalysisMetadata()
    ) -> StorageNode {
        StorageNode(
            name: URL(fileURLWithPath: path).lastPathComponent,
            absolutePath: path,
            logicalSize: logical ?? allocated,
            allocatedSize: allocated,
            ownLogicalSize: logical ?? allocated,
            ownAllocatedSize: allocated,
            itemType: .directory,
            children: children,
            accessibility: accessibility,
            scanIssues: issues,
            isHidden: hidden,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: metadata
        )
    }

    static func developerReport(
        optState: DeveloperSystemRootState = .present,
        optSize: Int64 = 70
    ) -> DeveloperSystemStorageReport {
        let optResult = result(path: "/opt", allocated: optSize)
        let usrResult = result(path: "/usr/local", allocated: 80)
        return DeveloperSystemStorageReport(
            opt: DeveloperSystemRootAnalysis(
                canonicalRoot: .opt,
                configuredPath: "/opt",
                state: optState,
                result: optResult
            ),
            usrLocal: DeveloperSystemRootAnalysis(
                canonicalRoot: .usrLocal,
                configuredPath: "/usr/local",
                state: .present,
                result: usrResult
            ),
            combinedUniqueLogicalSize: optSize + 80,
            combinedUniqueAllocatedSize: optSize + 80,
            combinedSizeKnowledge: .complete,
            wasCancelled: false,
            issues: []
        )
    }

    static func dockerReport(
        hostLocations: [StorageAnalysisResult],
        runtimeBytes: Int64? = nil,
        runtimeLocation: DockerRuntimeLocation = .local
    ) -> DockerStorageReport {
        let runtime = runtimeBytes.map {
            DockerRuntimeAccounting(
                images: DockerRuntimeStorageUsage(
                    category: .images,
                    totalBytes: $0,
                    reclaimableBytes: 0,
                    reclaimablePercentage: 0,
                    objectCount: 1,
                    activeCount: 1
                ),
                containers: nil,
                localVolumes: nil,
                buildCache: nil
            )
        }
        let relationship: DockerHostRuntimeRelationship
        switch runtimeLocation {
        case .local: relationship = .localRuntimeMayExplainHostFootprint
        case .remote: relationship = .remoteRuntimeNotRelatedToHostFootprint
        case .unknown: relationship = .unknownRelationship
        }
        return DockerStorageReport(
            hostFootprint: DockerHostFootprint(
                locations: hostLocations,
                logicalSize: hostLocations.reduce(0) { $0 + $1.root.logicalSize },
                allocatedSize: hostLocations.reduce(0) { $0 + $1.root.allocatedSize }
            ),
            virtualDisks: [],
            runtimeStatus: runtime == nil ? .notInstalled : .installedAndReachable,
            runtimeAccounting: runtime,
            dockerExecutablePath: nil,
            runtimeContext: DockerRuntimeContext(
                name: "test",
                sanitizedEndpoint: runtimeLocation == .remote ? "ssh://remote" : "unix:///local.sock",
                location: runtimeLocation
            ),
            hostRuntimeRelationship: relationship,
            accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
            wasCancelled: false,
            issues: []
        )
    }

    static func apfsReport(used: Int64, snapshotSize: Int64? = nil) -> APFSStorageReport {
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

    func testCoordinatorWiresRunCacheAcrossLiveAnalyzersAndRecordsAvoidedTraversals() async throws {
        let coordinator = StorageAnalysisCoordinator(
            userHomeStorageAnalysis: {
                Self.userHomeReport(roots: [("/Users/test/Documents", 1000)])
            },
            applicationsAnalysis: {
                Self.result(path: "/Applications", allocated: 1000)
            },
            systemLibraryAnalysis: {
                Self.result(path: "/Library", allocated: 1000)
            },
            privateStorageAnalysis: {
                Self.result(path: "/private", allocated: 1000)
            },
            dataVolumeHiddenStorageAnalysis: {
                Self.result(path: "/System/Volumes/Data/.hidden", allocated: 1000)
            },
            developerSystemStorageAnalysis: {
                Self.developerReport(optSize: 1000)
            },
            apfsStorageAnalysis: {
                Self.apfsReport(used: 10000)
            },
            coverageExpansionAnalysis: {
                StorageCoverageExpansionReport.empty
            },
            coverageDiscovery: {
                StorageCoverageDiscoveryResult(
                    homeDirectoryPath: "/Users/test",
                    hiddenHomeEntries: [],
                    unspecializedLibraryEntries: [],
                    issues: [],
                    wasCancelled: false
                )
            }
        )

        let report = await coordinator.analyze()
        XCTAssertGreaterThan(report.filesystemContributions.count, 0)
    }
}

private actor ProgressRecorder {
    private(set) var values: [StorageAnalysisProgress] = []

    func append(_ value: StorageAnalysisProgress) {
        values.append(value)
    }
}
