import Darwin
import XCTest
@testable import PureMac

final class StoragePathNormalizerTests: XCTestCase {
    // MARK: - 1. /System/Volumes/Data/private/var/x and /private/var/x
    func testDataVolumePrivateVarNormalizesToPrivateVar() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/private/var/agentx"),
            "/private/var/agentx"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/private/var/agentx"),
            "/private/var/agentx"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/private/var/agentx"),
            StoragePathNormalizer.normalize("/private/var/agentx")
        )
    }

    // MARK: - 2. /var/x and /private/var/x macOS canonical alias semantics
    func testVarNormalizesToPrivateVar() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/var/agentx"),
            "/private/var/agentx"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/var"),
            "/private/var"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/var/log/system.log"),
            "/private/var/log/system.log"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/var/agentx"),
            StoragePathNormalizer.normalize("/private/var/agentx")
        )
    }

    // MARK: - 3. /etc/x and /private/etc/x
    func testEtcNormalizesToPrivateEtc() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/etc/cups/certs"),
            "/private/etc/cups/certs"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/etc"),
            "/private/etc"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/private/etc/cups/certs"),
            "/private/etc/cups/certs"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/etc/cups/certs"),
            StoragePathNormalizer.normalize("/private/etc/cups/certs")
        )
    }

    // MARK: - 4. /tmp/x and /private/tmp/x
    func testTmpNormalizesToPrivateTmp() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/tmp/scratch.txt"),
            "/private/tmp/scratch.txt"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/tmp"),
            "/private/tmp"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/private/tmp/scratch.txt"),
            "/private/tmp/scratch.txt"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/tmp/scratch.txt"),
            StoragePathNormalizer.normalize("/private/tmp/scratch.txt")
        )
    }

    // MARK: - 5. /System/Volumes/Data/Users/... and /Users/...
    func testDataVolumeUsersNormalizesToUsers() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/Users/alice/Library"),
            "/Users/alice/Library"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/Users"),
            "/Users"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/Users/alice/Library"),
            "/Users/alice/Library"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/Users/alice"),
            StoragePathNormalizer.normalize("/Users/alice")
        )
    }

    func testOtherDataVolumeFirmlinks() {
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/Library/Preferences"),
            "/Library/Preferences"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/Applications/PureMac.app"),
            "/Applications/PureMac.app"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/opt/homebrew"),
            "/opt/homebrew"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/usr/local/bin"),
            "/usr/local/bin"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/.Spotlight-V100"),
            "/System/Volumes/Data/.Spotlight-V100"
        )
        XCTAssertEqual(
            StoragePathNormalizer.normalize("/System/Volumes/Data/.DocumentRevisions-V100"),
            "/System/Volumes/Data/.DocumentRevisions-V100"
        )
    }

    // MARK: - 6. Similar prefixes are NOT treated as aliases
    func testSimilarPrefixesAreNotTreatedAsAliases() {
        XCTAssertEqual(StoragePathNormalizer.normalize("/private2"), "/private2")
        XCTAssertEqual(StoragePathNormalizer.normalize("/private2/var"), "/private2/var")
        XCTAssertEqual(StoragePathNormalizer.normalize("/various"), "/various")
        XCTAssertEqual(StoragePathNormalizer.normalize("/various/sub"), "/various/sub")
        XCTAssertEqual(StoragePathNormalizer.normalize("/var_log"), "/var_log")
        XCTAssertEqual(StoragePathNormalizer.normalize("/etc2"), "/etc2")
        XCTAssertEqual(StoragePathNormalizer.normalize("/etc_hosts"), "/etc_hosts")
        XCTAssertEqual(StoragePathNormalizer.normalize("/tmp_file"), "/tmp_file")
        XCTAssertEqual(StoragePathNormalizer.normalize("/tmp2/test"), "/tmp2/test")
        XCTAssertEqual(StoragePathNormalizer.normalize("/System/Volumes/Database"), "/System/Volumes/Database")
        XCTAssertEqual(StoragePathNormalizer.normalize("/System/Volumes/Data2/private"), "/System/Volumes/Data2/private")
        XCTAssertEqual(StoragePathNormalizer.normalize("/System/Volumes/Data/private2"), "/System/Volumes/Data/private2")
        XCTAssertEqual(StoragePathNormalizer.normalize("/System/Volumes/Data/Users2"), "/System/Volumes/Data/Users2")
    }

    // MARK: - 7. Arbitrary symlinks are not resolved/followed
    func testArbitrarySymlinksAreNotResolved() {
        let path = "/Users/alice/my_symlink/target"
        XCTAssertEqual(StoragePathNormalizer.normalize(path), "/Users/alice/my_symlink/target")
    }

    // MARK: - 8. Equivalent permission-denied paths reached by two analyzers
    func testEquivalentPermissionDeniedPathsRepresentedAsOneDiagnosticLocation() {
        let issue1 = StorageScanIssue(
            path: "/System/Volumes/Data/private/var/agentx",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )
        let issue2 = StorageScanIssue(
            path: "/private/var/agentx",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )

        var results = StorageAnalyzerResults()
        results.dataVolumeHiddenStorage = makeResult(path: "/System/Volumes/Data", issues: [issue1])
        results.privateStorage = makeResult(path: "/private", issues: [issue2])

        let coverage = [
            StorageCanonicalRootCoverage(root: .dataVolumeHiddenStorage, configuredPath: "/System/Volumes/Data", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 1),
            StorageCanonicalRootCoverage(root: .privateStorage, configuredPath: "/private", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 1),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        XCTAssertEqual(diagnostic.measurementIssues.totalIssueCount, 1)
        XCTAssertEqual(diagnostic.permissionDeniedIssueCount, 1)
        XCTAssertEqual(diagnostic.measurementIssues.groups.count, 1)

        let group = diagnostic.measurementIssues.groups[0]
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group.posixErrorCode, EACCES)
        XCTAssertEqual(group.category, .permissionDenied)
        XCTAssertEqual(group.contributingSources.count, 2)
        XCTAssertTrue(group.contributingSources.contains(.analyzer(.dataVolumeHiddenStorage)))
        XCTAssertTrue(group.contributingSources.contains(.analyzer(.privateStorage)))
        XCTAssertTrue(group.representativePaths.contains("/System/Volumes/Data/private/var/agentx") || group.representativePaths.contains("/private/var/agentx"))
    }

    // MARK: - 9. Different errno values are not incorrectly merged
    func testDifferentErrnoValuesAreNotMerged() {
        let issueEaccess = StorageScanIssue(
            path: "/private/var/agentx",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )
        let issueEperm = StorageScanIssue(
            path: "/private/var/agentx",
            kind: .permissionDenied,
            message: "Operation not permitted.",
            posixErrorCode: EPERM
        )

        var results = StorageAnalyzerResults()
        results.privateStorage = makeResult(path: "/private", issues: [issueEaccess, issueEperm])

        let coverage = [
            StorageCanonicalRootCoverage(root: .privateStorage, configuredPath: "/private", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 2),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        XCTAssertEqual(diagnostic.measurementIssues.totalIssueCount, 2)
        XCTAssertEqual(diagnostic.measurementIssues.errnoCounts.count, 2)
        XCTAssertTrue(diagnostic.measurementIssues.errnoCounts.contains { $0.errorCode == EACCES && $0.count == 1 })
        XCTAssertTrue(diagnostic.measurementIssues.errnoCounts.contains { $0.errorCode == EPERM && $0.count == 1 })
    }

    // MARK: - 10. Different issue categories are not incorrectly merged
    func testDifferentCategoriesAreNotMerged() {
        let issueDenied = StorageScanIssue(
            path: "/private/var/db",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )
        let issueEnumFailed = StorageScanIssue(
            path: "/private/var/db",
            kind: .directoryEnumerationFailed,
            message: "Directory enumeration failed.",
            posixErrorCode: EIO
        )

        var results = StorageAnalyzerResults()
        results.privateStorage = makeResult(path: "/private", issues: [issueDenied, issueEnumFailed])

        let coverage = [
            StorageCanonicalRootCoverage(root: .privateStorage, configuredPath: "/private", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 2),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        XCTAssertEqual(diagnostic.measurementIssues.totalIssueCount, 2)
        XCTAssertEqual(diagnostic.permissionDeniedIssueCount, 1)
        XCTAssertEqual(diagnostic.measurementIssues.categoryCounts.first { $0.category == .enumerationFailure }?.count, 1)
    }

    // MARK: - 11. Original/display paths remain available
    func testOriginalDisplayPathsRemainAvailable() {
        let originalPath = "/System/Volumes/Data/private/etc/cups/certs"
        let issue = StorageScanIssue(
            path: originalPath,
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )

        var results = StorageAnalyzerResults()
        results.dataVolumeHiddenStorage = makeResult(path: "/System/Volumes/Data", issues: [issue])

        let coverage = [
            StorageCanonicalRootCoverage(root: .dataVolumeHiddenStorage, configuredPath: "/System/Volumes/Data", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 1),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        let group = diagnostic.measurementIssues.groups.first
        XCTAssertNotNil(group)
        XCTAssertTrue(group?.representativePaths.contains(originalPath) == true)
    }

    // MARK: - 12. Canonical accounting ownership prevents duplicate additive bytes
    func testCanonicalAccountingOwnershipPreventsDuplicateBytes() async {
        let coordinator = makeCoordinator(
            privateStorage: self.makeResult(path: "/private", allocated: 100),
            hidden: self.makeResult(path: "/System/Volumes/Data", allocated: 100, children: [
                self.makeNode(path: "/System/Volumes/Data/private", allocated: 100)
            ])
        )
        let report = await coordinator.analyze()

        let privateContrib = report.filesystemContributions.first { $0.source == .privateStorage }
        let dataVolumeContrib = report.filesystemContributions.first { $0.source == .dataVolumeHiddenStorage }

        XCTAssertEqual(dataVolumeContrib?.relationship, .canonicalUnique)
        XCTAssertEqual(dataVolumeContrib?.accountedAllocatedBytes, 100)

        XCTAssertEqual(privateContrib?.relationship, .excludedDuplicatePath)
        XCTAssertEqual(privateContrib?.accountedAllocatedBytes, 0)
        XCTAssertEqual(privateContrib?.owningPath, "/private")
    }

    // MARK: - 13. explainedAllocatedBytes does not increase due to alias normalization
    func testExplainedAllocatedBytesDoesNotIncreaseDueToAliasNormalization() async {
        let coordinator = makeCoordinator(
            privateStorage: self.makeResult(path: "/private", allocated: 50),
            hidden: self.makeResult(path: "/System/Volumes/Data", allocated: 50, children: [
                self.makeNode(path: "/System/Volumes/Data/private", allocated: 50)
            ])
        )
        let report = await coordinator.analyze()

        XCTAssertEqual(report.explainedAllocatedBytes, 50)
    }

    // MARK: - 14. unexplained-byte arithmetic remains max(volumeUsed - explained, 0)
    func testUnexplainedBytesArithmeticRemainsMaxUsedMinusExplained() async {
        let coordinator = makeCoordinator(
            privateStorage: self.makeResult(path: "/private", allocated: 80)
        )
        let report = await coordinator.analyze()

        if let used = report.usedCapacityBytes {
            XCTAssertEqual(report.unexplainedBytes, max(used - report.explainedAllocatedBytes, 0))
        } else {
            XCTAssertNil(report.unexplainedBytes)
        }
    }

    // MARK: - 15. Docker overlap checks respect normalized canonical identities
    func testDockerOverlapRespectsNormalizedCanonicalIdentities() async {
        let node = self.makeNode(path: "/System/Volumes/Data/private/var/run/docker.sock", allocated: 10)
        let location = StorageAnalysisResult(root: node, startedAt: Date(), completedAt: Date(), rootDeviceIdentifier: nil, wasCancelled: false, issues: [])
        let footprint = DockerHostFootprint(locations: [location], logicalSize: 10, allocatedSize: 10)
        let dockerReport = DockerStorageReport(
            hostFootprint: footprint,
            virtualDisks: [],
            runtimeStatus: .installedAndReachable,
            runtimeAccounting: nil,
            dockerExecutablePath: nil,
            runtimeContext: DockerRuntimeContext(
                name: "default",
                sanitizedEndpoint: "unix:///var/run/docker.sock",
                location: .local
            ),
            hostRuntimeRelationship: .localRuntimeMayExplainHostFootprint,
            accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
            wasCancelled: false,
            issues: []
        )

        let coordinator = makeCoordinator(
            privateStorage: self.makeResult(path: "/private", allocated: 40),
            docker: dockerReport
        )
        let report = await coordinator.analyze()

        let dockerContrib = report.filesystemContributions.first { $0.source == .dockerHostOutsideCanonicalRoots }
        XCTAssertNotNil(dockerContrib)
        XCTAssertEqual(dockerContrib?.relationship, .excludedNestedPath)
        XCTAssertEqual(dockerContrib?.accountedAllocatedBytes, 0)
        XCTAssertEqual(dockerContrib?.owningPath, "/private")
    }

    // MARK: - 17. FDA granted + EACCES does not generate "grant FDA" guidance
    @MainActor
    func testFDAGrantedWithEACCESDoesNotRecommendGrantingFDA() {
        let state = StorageIntelligenceState(analysisRunner: { _ in
            StorageReconciliationReport(
                totalCapacityBytes: 1_000,
                usedCapacityBytes: 800,
                availableCapacityBytes: 200,
                purgeableEstimateBytes: nil,
                explainedAllocatedBytes: 100,
                unexplainedBytes: 700,
                inaccessibleKnownLowerBoundBytes: 0,
                unreadablePathCount: 0,
                incompleteCoverage: false,
                coverageStatus: .completeForConfiguredRoots,
                canonicalRootCoverage: [],
                filesystemContributions: [],
                hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
                analysisIssues: [],
                analyzerResults: StorageAnalyzerResults(),
                coverageDiagnostic: .empty,
                startedAt: Date(),
                completedAt: Date(),
                duration: 0,
                progress: StorageAnalysisProgress(totalStages: 10, completedStages: 10, runningStages: [], state: .completed),
                wasCancelled: false
            )
        })
        let guidance = state.permissionGuidance(fullDiskAccessGranted: true)
        XCTAssertNil(guidance)
    }

    // MARK: - 19. Known protected-system paths receive appropriate explanatory classification
    func testSystemProtectedLocationsClassification() {
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/System/Volumes/Data/.DocumentRevisions-V100"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/System/Volumes/Data/.Spotlight-V100"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/System/Volumes/Data/.fseventsd"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/private/var/audit"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/var/audit"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/System/Volumes/Data/private/var/agentx"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/private/etc/cups/certs"))
        XCTAssertTrue(StoragePathNormalizer.isSystemProtectedLocation("/etc/cups/certs"))

        XCTAssertFalse(StoragePathNormalizer.isSystemProtectedLocation("/Users/alice/Documents"))
        XCTAssertFalse(StoragePathNormalizer.isSystemProtectedLocation("/private/tmp/scratch"))
        XCTAssertFalse(StoragePathNormalizer.isSystemProtectedLocation("/opt/homebrew"))
    }

    func testSystemProtectedLocationReceivesAccurateExplanation() {
        let issue = StorageScanIssue(
            path: "/private/var/audit",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )

        var results = StorageAnalyzerResults()
        results.privateStorage = makeResult(path: "/private", issues: [issue])

        let coverage = [
            StorageCanonicalRootCoverage(root: .privateStorage, configuredPath: "/private", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 1),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/test"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        let group = diagnostic.measurementIssues.groups.first
        XCTAssertNotNil(group)
        XCTAssertTrue(group?.explanation.contains("system-managed") == true)
    }

    // MARK: - 20. Unknown inaccessible paths remain unknown/inaccessible rather than being guessed
    func testUnknownInaccessiblePathIsNotClassifiedAsProtected() {
        let issue = StorageScanIssue(
            path: "/Users/alice/secret_custom_folder",
            kind: .permissionDenied,
            message: "Permission denied.",
            posixErrorCode: EACCES
        )

        var results = StorageAnalyzerResults()
        results.userHomeStorage = UserHomeStorageAnalyzer.makeReport(
            makeResult(path: "/Users/alice", issues: [issue]),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/alice"),
            largeAllocatedSizeThreshold: 1_073_741_824
        )

        let coverage = [
            StorageCanonicalRootCoverage(root: .userHomeVisibleStorage, configuredPath: "/Users/alice", state: .completed, knownAllocatedBytes: 10, unreadablePathCount: 1),
        ]

        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: [],
            analysisIssues: [],
            discovery: .empty(homeDirectoryPath: "/Users/alice"),
            unexplainedBytes: 0,
            purgeableEstimateBytes: nil,
            incompleteCoverage: false,
            wasCancelled: false
        )

        let group = diagnostic.measurementIssues.groups.first
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.explanation, StorageCoverageDiagnosticBuilder.explanation(for: .permissionDenied))
        XCTAssertFalse(group?.explanation.contains("system-managed") == true)
    }

    // MARK: - Path containment and overlap helpers
    func testPathContainmentAndOverlap() {
        XCTAssertTrue(StoragePathNormalizer.contains(parent: "/private", child: "/private/var/agentx"))
        XCTAssertTrue(StoragePathNormalizer.contains(parent: "/private", child: "/System/Volumes/Data/private/var/agentx"))
        XCTAssertTrue(StoragePathNormalizer.contains(parent: "/private", child: "/var/agentx"))
        XCTAssertTrue(StoragePathNormalizer.contains(parent: "/System/Volumes/Data/private", child: "/private/var/agentx"))
        XCTAssertTrue(StoragePathNormalizer.contains(parent: "/Users", child: "/System/Volumes/Data/Users/alice"))

        XCTAssertFalse(StoragePathNormalizer.contains(parent: "/private", child: "/private2"))
        XCTAssertFalse(StoragePathNormalizer.contains(parent: "/private", child: "/Users/alice"))

        XCTAssertTrue(StoragePathNormalizer.pathsOverlap("/private", "/private/var"))
        XCTAssertTrue(StoragePathNormalizer.pathsOverlap("/private/var", "/private"))
        XCTAssertTrue(StoragePathNormalizer.pathsOverlap("/System/Volumes/Data/private", "/var/log"))
        XCTAssertFalse(StoragePathNormalizer.pathsOverlap("/private", "/Users"))

        XCTAssertEqual(StoragePathNormalizer.parentPath(of: "/System/Volumes/Data/private/var/agentx"), "/private/var")
        XCTAssertEqual(StoragePathNormalizer.parentPath(of: "/var/agentx"), "/private/var")
        XCTAssertEqual(StoragePathNormalizer.parentPath(of: "/private/etc/cups/certs"), "/private/etc/cups")
        XCTAssertEqual(StoragePathNormalizer.parentPath(of: "/"), "/")
    }

    // MARK: - Helpers
    private func makeNode(path: String, allocated: Int64 = 0, children: [StorageNode] = []) -> StorageNode {
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

    struct TestStageNotRun: Error {}

    private func makeCoordinator(
        userHome: UserHomeStorageReport? = nil,
        applicationSupport: StorageAnalysisResult? = nil,
        containers: StorageAnalysisResult? = nil,
        groupContainers: StorageAnalysisResult? = nil,
        systemLibrary: StorageAnalysisResult? = nil,
        privateStorage: StorageAnalysisResult? = nil,
        hidden: StorageAnalysisResult? = nil,
        developer: DeveloperSystemStorageReport? = nil,
        docker: DockerStorageReport? = nil,
        apfs: APFSStorageReport? = nil,
        coverageExpansion: StorageCoverageExpansionReport? = nil
    ) -> StorageAnalysisCoordinator {
        StorageAnalysisCoordinator(
            userHomeStorageAnalysis: {
                if let userHome { return userHome }
                throw TestStageNotRun()
            },
            applicationSupportAnalysis: {
                if let applicationSupport { return applicationSupport }
                throw TestStageNotRun()
            },
            containersAnalysis: {
                if let containers { return containers }
                throw TestStageNotRun()
            },
            groupContainersAnalysis: {
                if let groupContainers { return groupContainers }
                throw TestStageNotRun()
            },
            systemLibraryAnalysis: {
                if let systemLibrary { return systemLibrary }
                throw TestStageNotRun()
            },
            privateStorageAnalysis: {
                if let privateStorage { return privateStorage }
                throw TestStageNotRun()
            },
            dataVolumeHiddenStorageAnalysis: {
                if let hidden { return hidden }
                throw TestStageNotRun()
            },
            developerSystemStorageAnalysis: {
                if let developer { return developer }
                throw TestStageNotRun()
            },
            dockerStorageAnalysis: {
                if let docker { return docker }
                throw TestStageNotRun()
            },
            apfsStorageAnalysis: {
                if let apfs { return apfs }
                throw TestStageNotRun()
            },
            coverageExpansionAnalysis: {
                if let coverageExpansion { return coverageExpansion }
                return .empty
            },
            coverageDiscovery: { .empty(homeDirectoryPath: "/Users/test") }
        )
    }
}
