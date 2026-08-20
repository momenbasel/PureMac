import Foundation

/// Coordinates the existing read-only storage analyzers and reconciles their
/// results without coupling storage intelligence to cleanup behavior.
struct StorageAnalysisCoordinator: Sendable {
    typealias FilesystemAnalysis = @Sendable () async throws -> StorageAnalysisResult
    typealias DeveloperAnalysis = @Sendable () async throws -> DeveloperSystemStorageReport
    typealias DockerAnalysis = @Sendable () async throws -> DockerStorageReport
    typealias APFSAnalysis = @Sendable () async throws -> APFSStorageReport
    typealias UserHomeAnalysis = @Sendable () async throws -> UserHomeStorageReport
    typealias CoverageExpansionAnalysis = @Sendable () async throws -> StorageCoverageExpansionReport
    typealias CoverageDiscovery = @Sendable () async -> StorageCoverageDiscoveryResult
    typealias ProgressHandler = @Sendable (StorageAnalysisProgress) async -> Void

    private let applicationSupportAnalysis: FilesystemAnalysis
    private let containersAnalysis: FilesystemAnalysis
    private let groupContainersAnalysis: FilesystemAnalysis
    private let systemLibraryAnalysis: FilesystemAnalysis
    private let privateStorageAnalysis: FilesystemAnalysis
    private let dataVolumeHiddenStorageAnalysis: FilesystemAnalysis
    private let developerSystemStorageAnalysis: DeveloperAnalysis
    private let dockerStorageAnalysis: DockerAnalysis
    private let apfsStorageAnalysis: APFSAnalysis
    private let userHomeStorageAnalysis: UserHomeAnalysis
    private let coverageExpansionAnalysis: CoverageExpansionAnalysis
    private let coverageDiscovery: CoverageDiscovery
    private let maxConcurrentAnalyzers: Int

    init(
        maxConcurrentAnalyzers: Int = 2,
        userHomeStorageAnalysis: @escaping UserHomeAnalysis = {
            await UserHomeStorageAnalyzer().analyze()
        },
        applicationSupportAnalysis: @escaping FilesystemAnalysis = {
            await ApplicationSupportAnalyzer().analyze()
        },
        containersAnalysis: @escaping FilesystemAnalysis = {
            await ContainersAnalyzer().analyze()
        },
        groupContainersAnalysis: @escaping FilesystemAnalysis = {
            await GroupContainersAnalyzer().analyze()
        },
        systemLibraryAnalysis: @escaping FilesystemAnalysis = {
            await SystemLibraryAnalyzer().analyze()
        },
        privateStorageAnalysis: @escaping FilesystemAnalysis = {
            await PrivateStorageAnalyzer().analyze()
        },
        dataVolumeHiddenStorageAnalysis: @escaping FilesystemAnalysis = {
            await DataVolumeHiddenStorageAnalyzer().analyze()
        },
        developerSystemStorageAnalysis: @escaping DeveloperAnalysis = {
            await DeveloperSystemStorageAnalyzer().analyze()
        },
        dockerStorageAnalysis: @escaping DockerAnalysis = {
            await DockerStorageAnalyzer().analyze()
        },
        apfsStorageAnalysis: @escaping APFSAnalysis = {
            await APFSStorageAnalyzer().analyze()
        },
        coverageExpansionAnalysis: @escaping CoverageExpansionAnalysis = {
            await CoverageExpansionAnalyzer().analyze()
        },
        coverageDiscovery: @escaping CoverageDiscovery = {
            await StorageCoverageGapDiscovery().discover()
        }
    ) {
        self.maxConcurrentAnalyzers = min(max(maxConcurrentAnalyzers, 1), 3)
        self.applicationSupportAnalysis = applicationSupportAnalysis
        self.containersAnalysis = containersAnalysis
        self.groupContainersAnalysis = groupContainersAnalysis
        self.systemLibraryAnalysis = systemLibraryAnalysis
        self.privateStorageAnalysis = privateStorageAnalysis
        self.dataVolumeHiddenStorageAnalysis = dataVolumeHiddenStorageAnalysis
        self.developerSystemStorageAnalysis = developerSystemStorageAnalysis
        self.dockerStorageAnalysis = dockerStorageAnalysis
        self.apfsStorageAnalysis = apfsStorageAnalysis
        self.userHomeStorageAnalysis = userHomeStorageAnalysis
        self.coverageExpansionAnalysis = coverageExpansionAnalysis
        self.coverageDiscovery = coverageDiscovery
    }

    /// Runs away from the main actor. Independent stages use a small bounded
    /// task group to avoid launching every disk-intensive tree scan at once.
    func analyze(progress progressHandler: ProgressHandler? = nil) async -> StorageReconciliationReport {
        let startedAt = Date()
        let operations = makeOperations()
        let discoveryTask = Task(priority: .utility) {
            await coverageDiscovery()
        }
        var outputs: [StorageAnalyzerStage: StageOutput] = [:]
        var failures: [StorageAnalyzerStage: String] = [:]
        var completedStages: Set<StorageAnalyzerStage> = []
        var runningStages: Set<StorageAnalyzerStage> = []

        await progressHandler?(StorageAnalysisProgress(
            totalStages: operations.count,
            completedStages: 0,
            runningStages: [],
            state: Task.isCancelled ? .cancelled : .running
        ))

        if !Task.isCancelled {
            await withTaskGroup(of: StageExecution.self) { group in
                let initialCount = min(maxConcurrentAnalyzers, operations.count)
                for operation in operations.prefix(initialCount) {
                    runningStages.insert(operation.stage)
                    group.addTask { await Self.execute(operation) }
                }

                await progressHandler?(Self.progress(
                    total: operations.count,
                    completed: completedStages,
                    running: runningStages,
                    state: .running
                ))

                var nextIndex = initialCount
                while let execution = await group.next() {
                    runningStages.remove(execution.stage)
                    completedStages.insert(execution.stage)

                    switch execution.result {
                    case let .success(output):
                        outputs[execution.stage] = output
                    case let .failure(message):
                        failures[execution.stage] = message
                    case .cancelled:
                        failures[execution.stage] = "Analysis was cancelled."
                    }

                    if Task.isCancelled {
                        group.cancelAll()
                    } else if nextIndex < operations.count {
                        let operation = operations[nextIndex]
                        nextIndex += 1
                        runningStages.insert(operation.stage)
                        group.addTask { await Self.execute(operation) }
                    }

                    await progressHandler?(Self.progress(
                        total: operations.count,
                        completed: completedStages,
                        running: runningStages,
                        state: Task.isCancelled ? .cancelled : .running
                    ))
                }
            }
        }

        if Task.isCancelled {
            discoveryTask.cancel()
        }
        let discovery = await discoveryTask.value

        let completedAt = Date()
        let report = await Self.reconcile(
            outputs: outputs,
            failures: failures,
            startedAt: startedAt,
            completedAt: completedAt,
            discovery: discovery,
            coordinatorWasCancelled: Task.isCancelled,
            completedStageCount: completedStages.count,
            totalStageCount: operations.count
        )
        await progressHandler?(report.progress)
        return report
    }
}

// MARK: - Stage Execution

private extension StorageAnalysisCoordinator {
    enum StageOutput: Sendable {
        case applicationSupport(StorageAnalysisResult)
        case containers(StorageAnalysisResult)
        case groupContainers(StorageAnalysisResult)
        case systemLibrary(StorageAnalysisResult)
        case privateStorage(StorageAnalysisResult)
        case dataVolumeHiddenStorage(StorageAnalysisResult)
        case developerSystemStorage(DeveloperSystemStorageReport)
        case dockerStorage(DockerStorageReport)
        case apfsStorage(APFSStorageReport)
        case userHomeStorage(UserHomeStorageReport)
        case coverageExpansion(StorageCoverageExpansionReport)
    }

    enum StageExecutionResult: Sendable {
        case success(StageOutput)
        case failure(String)
        case cancelled
    }

    struct StageExecution: Sendable {
        let stage: StorageAnalyzerStage
        let result: StageExecutionResult
    }

    struct StageOperation: Sendable {
        let stage: StorageAnalyzerStage
        let operation: @Sendable () async throws -> StageOutput
    }

    func makeOperations() -> [StageOperation] {
        [
            StageOperation(stage: .apfsVolume) {
                .apfsStorage(try await apfsStorageAnalysis())
            },
            StageOperation(stage: .userHomeStorage) {
                .userHomeStorage(try await userHomeStorageAnalysis())
            },
            StageOperation(stage: .applicationSupport) {
                .applicationSupport(try await applicationSupportAnalysis())
            },
            StageOperation(stage: .containers) {
                .containers(try await containersAnalysis())
            },
            StageOperation(stage: .groupContainers) {
                .groupContainers(try await groupContainersAnalysis())
            },
            StageOperation(stage: .systemLibrary) {
                .systemLibrary(try await systemLibraryAnalysis())
            },
            StageOperation(stage: .privateStorage) {
                .privateStorage(try await privateStorageAnalysis())
            },
            StageOperation(stage: .dataVolumeHiddenStorage) {
                .dataVolumeHiddenStorage(try await dataVolumeHiddenStorageAnalysis())
            },
            StageOperation(stage: .developerSystemStorage) {
                .developerSystemStorage(try await developerSystemStorageAnalysis())
            },
            StageOperation(stage: .dockerStorage) {
                .dockerStorage(try await dockerStorageAnalysis())
            },
            StageOperation(stage: .coverageExpansion) {
                .coverageExpansion(try await coverageExpansionAnalysis())
            },
        ]
    }

    static func execute(_ operation: StageOperation) async -> StageExecution {
        guard !Task.isCancelled else {
            return StageExecution(stage: operation.stage, result: .cancelled)
        }
        do {
            let output = try await operation.operation()
            return StageExecution(
                stage: operation.stage,
                result: Task.isCancelled ? .cancelled : .success(output)
            )
        } catch is CancellationError {
            return StageExecution(stage: operation.stage, result: .cancelled)
        } catch {
            return StageExecution(
                stage: operation.stage,
                result: .failure(String(describing: error))
            )
        }
    }

    static func progress(
        total: Int,
        completed: Set<StorageAnalyzerStage>,
        running: Set<StorageAnalyzerStage>,
        state: StorageCoordinatorRunState
    ) -> StorageAnalysisProgress {
        StorageAnalysisProgress(
            totalStages: total,
            completedStages: completed.count,
            runningStages: running.sorted(by: stageSort),
            state: state
        )
    }

    static func stageSort(_ left: StorageAnalyzerStage, _ right: StorageAnalyzerStage) -> Bool {
        stageIndex(left) < stageIndex(right)
    }

    static func stageIndex(_ stage: StorageAnalyzerStage) -> Int {
        StorageAnalyzerStage.allCases.firstIndex(of: stage) ?? Int.max
    }
}

// MARK: - Reconciliation

private extension StorageAnalysisCoordinator {
    struct Candidate {
        let source: StorageAccountingSource
        let path: String
        let observedAllocatedBytes: Int64
    }

    static func reconcile(
        outputs: [StorageAnalyzerStage: StageOutput],
        failures: [StorageAnalyzerStage: String],
        startedAt: Date,
        completedAt: Date,
        discovery: StorageCoverageDiscoveryResult,
        coordinatorWasCancelled: Bool,
        completedStageCount: Int,
        totalStageCount: Int
    ) async -> StorageReconciliationReport {
        let results = analyzerResults(from: outputs)
        var issues = normalizedIssues(from: results)
        issues.append(contentsOf: failures.map { stage, message in
            StorageReconciliationIssue(
                kind: message == "Analysis was cancelled." ? .cancelled : .analyzerFailure,
                stage: stage,
                path: nil,
                message: message == "Analysis was cancelled."
                    ? message
                    : "The \(stage.rawValue) analyzer failed: \(message)"
            )
        })

        var coverage = canonicalCoverage(from: results, failures: failures, cancelled: coordinatorWasCancelled)
        coverage.sort { rootIndex($0.root) < rootIndex($1.root) }

        var canonicalCandidates = candidates(from: results)
        canonicalCandidates.sort(by: candidateOwnershipSort)
        var contributions = assignCanonicalOwnership(
            canonicalCandidates,
            developerReport: results.developerSystemStorage,
            issues: &issues
        )

        if let docker = results.dockerStorage {
            contributions.append(contentsOf: assignDockerOwnership(
                docker.hostFootprint.locations,
                existing: contributions,
                issues: &issues
            ))
        }

        contributions.sort(by: contributionSort)
        let explained = contributions
            .filter { $0.relationship == .canonicalUnique || $0.relationship == .externalSpecializedUnique }
            .reduce(Int64(0)) { saturatedAdd($0, $1.accountedAllocatedBytes) }

        let capacity = results.apfsStorage?.volume.capacity
        let used = capacity?.usedCapacity.map { max($0, 0) }
        let unexplained = used.map { max($0 - min(explained, $0), 0) }
        if let used, explained > used {
            issues.append(StorageReconciliationIssue(
                kind: .accountingAnomaly,
                stage: nil,
                path: nil,
                message: "Explained allocated bytes exceed the volume's reported used capacity; unexplained bytes were clamped to zero."
            ))
        }

        issues.append(StorageReconciliationIssue(
            kind: .crossAnalyzerHardLinkDeduplicationUnavailable,
            stage: nil,
            path: nil,
            message: "Hard links are deduplicated within analyzer scopes, but inode identity is not currently available for global deduplication across independent analyzer trees."
        ))
        issues = issues.uniqued().sorted(by: issueSort)

        let resultWasCancelled = coordinatorWasCancelled || resultsContainCancellation(results)
        let diagnostic = StorageCoverageDiagnosticBuilder().build(
            analyzerResults: results,
            canonicalRootCoverage: coverage,
            filesystemContributions: contributions,
            analysisIssues: issues,
            discovery: discovery,
            unexplainedBytes: unexplained,
            purgeableEstimateBytes: capacity?.purgeableEstimate.map { max($0, 0) },
            incompleteCoverage: true,
            wasCancelled: resultWasCancelled
        )
        let permissionIncomplete = diagnostic.permissionDeniedIssueCount > 0
        let failureIncomplete = !failures.isEmpty
        let measurementIncomplete = coverage.contains { $0.state == .partiallyCompleted }
            || diagnostic.measurementIssues.categoryCounts.contains {
                $0.count > 0 && $0.category != .missingOptionalRoot
            }
        let coverageStatus: StorageCoverageStatus
        if resultWasCancelled {
            coverageStatus = .partialDueToCancellation
        } else if failureIncomplete {
            coverageStatus = .partialDueToAnalyzerFailure
        } else if permissionIncomplete {
            coverageStatus = .partialDueToPermissions
        } else if measurementIncomplete {
            coverageStatus = .partialDueToMeasurementIssues
        } else {
            coverageStatus = .completeForConfiguredRoots
        }

        let partialSources = Set(coverage.filter {
            $0.state == .partiallyCompleted || $0.state == .failed
        }.map { accountingSource(for: $0.root) })
        let inaccessibleLowerBound = contributions
            .filter { partialSources.contains($0.source) }
            .reduce(Int64(0)) { saturatedAdd($0, $1.accountedAllocatedBytes) }
        let unreadableCount = coverage.reduce(0) { $0 + $1.unreadablePathCount }
        let finalProgress = StorageAnalysisProgress(
            totalStages: totalStageCount,
            completedStages: completedStageCount,
            runningStages: [],
            state: resultWasCancelled ? .cancelled : .completed
        )

        let initialReport = StorageReconciliationReport(
            totalCapacityBytes: capacity?.totalCapacity.map { max($0, 0) },
            usedCapacityBytes: used,
            availableCapacityBytes: capacity?.availableCapacity.map { max($0, 0) },
            purgeableEstimateBytes: capacity?.purgeableEstimate.map { max($0, 0) },
            explainedAllocatedBytes: explained,
            unexplainedBytes: unexplained,
            inaccessibleKnownLowerBoundBytes: inaccessibleLowerBound,
            unreadablePathCount: unreadableCount,
            incompleteCoverage: true,
            coverageStatus: coverageStatus,
            canonicalRootCoverage: coverage,
            filesystemContributions: contributions,
            hardLinkAccountingStatus: .deduplicatedWithinAnalyzerScopesOnly,
            analysisIssues: issues,
            analyzerResults: results,
            coverageDiagnostic: diagnostic,
            attributionReport: nil,
            startedAt: startedAt,
            completedAt: completedAt,
            duration: max(completedAt.timeIntervalSince(startedAt), 0),
            progress: finalProgress,
            wasCancelled: resultWasCancelled
        )

        let attribution = await StorageAttributionAnalyzer().analyze(reconciliationReport: initialReport)

        return StorageReconciliationReport(
            totalCapacityBytes: initialReport.totalCapacityBytes,
            usedCapacityBytes: initialReport.usedCapacityBytes,
            availableCapacityBytes: initialReport.availableCapacityBytes,
            purgeableEstimateBytes: initialReport.purgeableEstimateBytes,
            explainedAllocatedBytes: initialReport.explainedAllocatedBytes,
            unexplainedBytes: initialReport.unexplainedBytes,
            inaccessibleKnownLowerBoundBytes: initialReport.inaccessibleKnownLowerBoundBytes,
            unreadablePathCount: initialReport.unreadablePathCount,
            incompleteCoverage: initialReport.incompleteCoverage,
            coverageStatus: initialReport.coverageStatus,
            canonicalRootCoverage: initialReport.canonicalRootCoverage,
            filesystemContributions: initialReport.filesystemContributions,
            hardLinkAccountingStatus: initialReport.hardLinkAccountingStatus,
            analysisIssues: initialReport.analysisIssues,
            analyzerResults: initialReport.analyzerResults,
            coverageDiagnostic: initialReport.coverageDiagnostic,
            attributionReport: attribution,
            startedAt: initialReport.startedAt,
            completedAt: initialReport.completedAt,
            duration: initialReport.duration,
            progress: initialReport.progress,
            wasCancelled: initialReport.wasCancelled
        )
    }

    static func analyzerResults(
        from outputs: [StorageAnalyzerStage: StageOutput]
    ) -> StorageAnalyzerResults {
        var results = StorageAnalyzerResults(
            userHomeStorage: nil,
            applicationSupport: nil,
            containers: nil,
            groupContainers: nil,
            systemLibrary: nil,
            privateStorage: nil,
            dataVolumeHiddenStorage: nil,
            developerSystemStorage: nil,
            dockerStorage: nil,
            apfsStorage: nil,
            coverageExpansion: nil
        )
        for output in outputs.values {
            switch output {
            case let .userHomeStorage(value): results.userHomeStorage = value
            case let .applicationSupport(value): results.applicationSupport = value
            case let .containers(value): results.containers = value
            case let .groupContainers(value): results.groupContainers = value
            case let .systemLibrary(value): results.systemLibrary = value
            case let .privateStorage(value): results.privateStorage = value
            case let .dataVolumeHiddenStorage(value): results.dataVolumeHiddenStorage = value
            case let .developerSystemStorage(value): results.developerSystemStorage = value
            case let .dockerStorage(value): results.dockerStorage = value
            case let .apfsStorage(value): results.apfsStorage = value
            case let .coverageExpansion(value): results.coverageExpansion = value
            }
        }
        return results
    }
}

// MARK: - Canonical Roots

private extension StorageAnalysisCoordinator {
    static func candidates(from results: StorageAnalyzerResults) -> [Candidate] {
        var candidates: [Candidate] = []
        if let userHome = results.userHomeStorage {
            for root in userHome.roots {
                candidates.append(Candidate(
                    source: .userHomeVisibleStorage,
                    path: root.node.absolutePath,
                    observedAllocatedBytes: max(root.node.allocatedSize, 0)
                ))
            }
        }
        append(results.applicationSupport, source: .applicationSupport, to: &candidates)
        append(results.containers, source: .containers, to: &candidates)
        append(results.groupContainers, source: .groupContainers, to: &candidates)
        append(results.systemLibrary, source: .systemLibrary, to: &candidates)
        append(results.privateStorage, source: .privateStorage, to: &candidates)

        if let hidden = results.dataVolumeHiddenStorage {
            for child in hidden.root.children {
                candidates.append(Candidate(
                    source: .dataVolumeHiddenStorage,
                    path: child.absolutePath,
                    observedAllocatedBytes: max(child.allocatedSize, 0)
                ))
            }
        }

        if let developer = results.developerSystemStorage {
            append(developer.opt.result, source: .opt, to: &candidates)
            append(developer.usrLocal.result, source: .usrLocal, to: &candidates)
        }

        if let expansion = results.coverageExpansion {
            for candidate in expansion.candidates where candidate.status == .measured && candidate.contributesToExplainedBytes {
                candidates.append(Candidate(
                    source: .additionalCoverageGap,
                    path: candidate.originalPath,
                    observedAllocatedBytes: max(candidate.allocatedBytes ?? 0, 0)
                ))
            }
        }
        return candidates
    }

    static func append(
        _ result: StorageAnalysisResult?,
        source: StorageAccountingSource,
        to candidates: inout [Candidate]
    ) {
        guard let result else { return }
        candidates.append(Candidate(
            source: source,
            path: result.root.absolutePath,
            observedAllocatedBytes: max(result.root.allocatedSize, 0)
        ))
    }

    static func assignCanonicalOwnership(
        _ candidates: [Candidate],
        developerReport: DeveloperSystemStorageReport?,
        issues: inout [StorageReconciliationIssue]
    ) -> [StorageFilesystemContribution] {
        var includedPaths: [String] = []
        var contributions: [StorageFilesystemContribution] = []

        for candidate in candidates {
            let normalized = normalize(candidate.path)
            let owner = includedPaths.first { included in
                candidate.source == .userHomeVisibleStorage
                    ? pathsOverlap(included, normalized)
                    : containsPath(parent: included, child: normalized)
            }
            if let owner {
                let duplicate = owner == normalized
                contributions.append(StorageFilesystemContribution(
                    source: candidate.source,
                    absolutePath: candidate.path,
                    normalizedPath: normalized,
                    observedAllocatedBytes: candidate.observedAllocatedBytes,
                    accountedAllocatedBytes: 0,
                    relationship: duplicate ? .excludedDuplicatePath : .excludedNestedPath,
                    owningPath: owner
                ))
                issues.append(StorageReconciliationIssue(
                    kind: duplicate ? .duplicateRootExcluded : .nestedRootExcluded,
                    stage: stage(for: candidate.source),
                    path: candidate.path,
                    message: duplicate
                        ? "A duplicate canonical accounting root was excluded."
                        : "A canonical root nested inside \(owner) was retained as metadata but excluded from byte totals."
                ))
            } else {
                includedPaths.append(normalized)
                contributions.append(StorageFilesystemContribution(
                    source: candidate.source,
                    absolutePath: candidate.path,
                    normalizedPath: normalized,
                    observedAllocatedBytes: candidate.observedAllocatedBytes,
                    accountedAllocatedBytes: candidate.observedAllocatedBytes,
                    relationship: .canonicalUnique,
                    owningPath: nil
                ))
            }
        }

        if let developerReport {
            let developerIndices = contributions.indices.filter {
                contributions[$0].relationship == .canonicalUnique
                    && (contributions[$0].source == .opt || contributions[$0].source == .usrLocal)
            }.sorted { contributions[$0].source.rawValue < contributions[$1].source.rawValue }

            if developerIndices.count == 2 {
                var remaining = max(developerReport.combinedUniqueAllocatedSize, 0)
                for index in developerIndices {
                    let contribution = contributions[index]
                    let assigned = min(contribution.observedAllocatedBytes, remaining)
                    remaining -= assigned
                    contributions[index] = StorageFilesystemContribution(
                        source: contribution.source,
                        absolutePath: contribution.absolutePath,
                        normalizedPath: contribution.normalizedPath,
                        observedAllocatedBytes: contribution.observedAllocatedBytes,
                        accountedAllocatedBytes: assigned,
                        relationship: contribution.relationship,
                        owningPath: contribution.owningPath
                    )
                }
            }
        }
        return contributions
    }

    static func assignDockerOwnership(
        _ locations: [StorageAnalysisResult],
        existing: [StorageFilesystemContribution],
        issues: inout [StorageReconciliationIssue]
    ) -> [StorageFilesystemContribution] {
        let owners = existing.filter { $0.relationship == .canonicalUnique }
        var acceptedDockerPaths: [String] = []
        var additions: [StorageFilesystemContribution] = []

        for location in locations.sorted(by: { normalize($0.root.absolutePath) < normalize($1.root.absolutePath) }) {
            let path = location.root.absolutePath
            let normalized = normalize(path)
            if let owner = owners.first(where: {
                pathsOverlap($0.normalizedPath, normalized)
            }) {
                additions.append(StorageFilesystemContribution(
                    source: .dockerHostOutsideCanonicalRoots,
                    absolutePath: path,
                    normalizedPath: normalized,
                    observedAllocatedBytes: max(location.root.allocatedSize, 0),
                    accountedAllocatedBytes: 0,
                    relationship: owner.normalizedPath == normalized ? .excludedDuplicatePath : .excludedNestedPath,
                    owningPath: owner.normalizedPath
                ))
            } else if let owner = acceptedDockerPaths.first(where: { pathsOverlap($0, normalized) }) {
                additions.append(StorageFilesystemContribution(
                    source: .dockerHostOutsideCanonicalRoots,
                    absolutePath: path,
                    normalizedPath: normalized,
                    observedAllocatedBytes: max(location.root.allocatedSize, 0),
                    accountedAllocatedBytes: 0,
                    relationship: owner == normalized ? .excludedDuplicatePath : .excludedNestedPath,
                    owningPath: owner
                ))
            } else {
                acceptedDockerPaths.append(normalized)
                additions.append(StorageFilesystemContribution(
                    source: .dockerHostOutsideCanonicalRoots,
                    absolutePath: path,
                    normalizedPath: normalized,
                    observedAllocatedBytes: max(location.root.allocatedSize, 0),
                    accountedAllocatedBytes: max(location.root.allocatedSize, 0),
                    relationship: .externalSpecializedUnique,
                    owningPath: nil
                ))
            }
        }
        return additions
    }
}

// MARK: - Coverage and Issues

private extension StorageAnalysisCoordinator {
    static func canonicalCoverage(
        from results: StorageAnalyzerResults,
        failures: [StorageAnalyzerStage: String],
        cancelled: Bool
    ) -> [StorageCanonicalRootCoverage] {
        var coverage: [StorageCanonicalRootCoverage] = []
        coverage.append(coverageForUserHome(
            results.userHomeStorage,
            failed: failures[.userHomeStorage] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.applicationSupport,
            root: .applicationSupport,
            fallbackPath: ApplicationSupportAnalyzer.currentUserApplicationSupportURL.path,
            failed: failures[.applicationSupport] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.containers,
            root: .containers,
            fallbackPath: ContainersAnalyzer.currentUserContainersURL.path,
            failed: failures[.containers] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.groupContainers,
            root: .groupContainers,
            fallbackPath: GroupContainersAnalyzer.currentUserGroupContainersURL.path,
            failed: failures[.groupContainers] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.systemLibrary,
            root: .systemLibrary,
            fallbackPath: SystemLibraryAnalyzer.defaultSystemLibraryURL.path,
            failed: failures[.systemLibrary] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.privateStorage,
            root: .privateStorage,
            fallbackPath: PrivateStorageAnalyzer.defaultPrivateURL.path,
            failed: failures[.privateStorage] != nil,
            cancelled: cancelled
        ))
        coverage.append(coverageForResult(
            results.dataVolumeHiddenStorage,
            root: .dataVolumeHiddenStorage,
            fallbackPath: DataVolumeHiddenStorageAnalyzer.defaultDataVolumeURL.path,
            failed: failures[.dataVolumeHiddenStorage] != nil,
            cancelled: cancelled
        ))

        if let developer = results.developerSystemStorage {
            coverage.append(coverageForDeveloperRoot(developer.opt, root: .opt))
            coverage.append(coverageForDeveloperRoot(developer.usrLocal, root: .usrLocal))
        } else {
            let state: StorageCanonicalRootState = cancelled ? .cancelled : failures[.developerSystemStorage] == nil ? .missingOptional : .failed
            coverage.append(StorageCanonicalRootCoverage(
                root: .opt,
                configuredPath: DeveloperSystemStorageAnalyzer.defaultOptURL.path,
                state: state,
                knownAllocatedBytes: 0,
                unreadablePathCount: 0
            ))
            coverage.append(StorageCanonicalRootCoverage(
                root: .usrLocal,
                configuredPath: DeveloperSystemStorageAnalyzer.defaultUsrLocalURL.path,
                state: state,
                knownAllocatedBytes: 0,
                unreadablePathCount: 0
            ))
        }

        if let expansion = results.coverageExpansion {
            let unreadable = expansion.candidates.filter { $0.status == .inaccessible || $0.status == .failed }.count
            coverage.append(StorageCanonicalRootCoverage(
                root: .additionalCoverageGap,
                configuredPath: "Additional Coverage Gaps",
                state: expansion.wasCancelled ? .cancelled : (unreadable > 0 ? .partiallyCompleted : .completed),
                knownAllocatedBytes: expansion.totalNewlyMeasuredBytes,
                unreadablePathCount: unreadable
            ))
        }
        return coverage
    }

    static func coverageForUserHome(
        _ report: UserHomeStorageReport?,
        failed: Bool,
        cancelled: Bool
    ) -> StorageCanonicalRootCoverage {
        guard let report else {
            return StorageCanonicalRootCoverage(
                root: .userHomeVisibleStorage,
                configuredPath: UserHomeStorageAnalyzer.currentUserHomeURL.path,
                state: cancelled ? .cancelled : .failed,
                knownAllocatedBytes: 0,
                unreadablePathCount: 0
            )
        }
        return StorageCanonicalRootCoverage(
            root: .userHomeVisibleStorage,
            configuredPath: report.homeDirectoryPath,
            state: rootState(report.result, forcedFailure: failed),
            knownAllocatedBytes: max(report.combinedUniqueAllocatedSize, 0),
            unreadablePathCount: unreadableCount(in: report.result)
        )
    }

    static func coverageForResult(
        _ result: StorageAnalysisResult?,
        root: StorageCanonicalRoot,
        fallbackPath: String,
        failed: Bool,
        cancelled: Bool
    ) -> StorageCanonicalRootCoverage {
        guard let result else {
            return StorageCanonicalRootCoverage(
                root: root,
                configuredPath: fallbackPath,
                state: cancelled ? .cancelled : .failed,
                knownAllocatedBytes: 0,
                unreadablePathCount: 0
            )
        }
        return StorageCanonicalRootCoverage(
            root: root,
            configuredPath: result.root.absolutePath,
            state: rootState(result, forcedFailure: failed),
            knownAllocatedBytes: max(result.root.allocatedSize, 0),
            unreadablePathCount: unreadableCount(in: result)
        )
    }

    static func coverageForDeveloperRoot(
        _ analysis: DeveloperSystemRootAnalysis,
        root: StorageCanonicalRoot
    ) -> StorageCanonicalRootCoverage {
        let state: StorageCanonicalRootState
        switch analysis.state {
        case .present: state = .completed
        case .missing: state = .missingOptional
        case .inaccessible, .invalid: state = .failed
        case .partiallyReadable: state = .partiallyCompleted
        case .cancelled: state = .cancelled
        }
        return StorageCanonicalRootCoverage(
            root: root,
            configuredPath: analysis.configuredPath,
            state: state,
            knownAllocatedBytes: max(analysis.result.root.allocatedSize, 0),
            unreadablePathCount: unreadableCount(in: analysis.result)
        )
    }

    static func rootState(
        _ result: StorageAnalysisResult,
        forcedFailure: Bool
    ) -> StorageCanonicalRootState {
        if forcedFailure { return .failed }
        if result.wasCancelled || result.root.accessibility == .cancelled { return .cancelled }
        switch result.root.accessibility {
        case .accessible: return .completed
        case .partiallyAccessible, .skippedDifferentVolume: return .partiallyCompleted
        case .inaccessible: return .failed
        case .cancelled: return .cancelled
        }
    }

    static func unreadableCount(in result: StorageAnalysisResult) -> Int {
        Set(result.issues.filter {
            $0.kind == .permissionDenied
                || $0.kind == .unreadable
                || $0.kind == .directoryEnumerationFailed
                || $0.kind == .metadataUnavailable
        }.map(\.path)).count
    }

    static func normalizedIssues(from results: StorageAnalyzerResults) -> [StorageReconciliationIssue] {
        var issues: [StorageReconciliationIssue] = []
        appendIssues(results.userHomeStorage?.result, stage: .userHomeStorage, to: &issues)
        appendIssues(results.applicationSupport, stage: .applicationSupport, to: &issues)
        appendIssues(results.containers, stage: .containers, to: &issues)
        appendIssues(results.groupContainers, stage: .groupContainers, to: &issues)
        appendIssues(results.systemLibrary, stage: .systemLibrary, to: &issues)
        appendIssues(results.privateStorage, stage: .privateStorage, to: &issues)
        appendIssues(results.dataVolumeHiddenStorage, stage: .dataVolumeHiddenStorage, to: &issues)
        if let developer = results.developerSystemStorage {
            for issue in developer.issues {
                issues.append(reconciliationIssue(issue, stage: .developerSystemStorage))
            }
        }
        if let docker = results.dockerStorage {
            for issue in docker.issues {
                issues.append(StorageReconciliationIssue(
                    kind: issue.kind == .cancelled ? .cancelled : .analyzerIssue,
                    stage: .dockerStorage,
                    path: issue.path,
                    message: issue.message
                ))
            }
        }
        if let apfs = results.apfsStorage {
            for issue in apfs.issues {
                issues.append(StorageReconciliationIssue(
                    kind: issue.kind == .cancelled ? .cancelled : .analyzerIssue,
                    stage: .apfsVolume,
                    path: nil,
                    message: issue.message
                ))
            }
        }
        return issues
    }

    static func appendIssues(
        _ result: StorageAnalysisResult?,
        stage: StorageAnalyzerStage,
        to issues: inout [StorageReconciliationIssue]
    ) {
        guard let result else { return }
        issues.append(contentsOf: result.issues.map { reconciliationIssue($0, stage: stage) })
    }

    static func reconciliationIssue(
        _ issue: StorageScanIssue,
        stage: StorageAnalyzerStage
    ) -> StorageReconciliationIssue {
        let kind: StorageReconciliationIssueKind
        switch issue.kind {
        case .permissionDenied, .unreadable, .directoryEnumerationFailed, .metadataUnavailable:
            kind = .permissionIncomplete
        case .cancelled:
            kind = .cancelled
        default:
            kind = .analyzerIssue
        }
        return StorageReconciliationIssue(
            kind: kind,
            stage: stage,
            path: issue.path,
            message: issue.message
        )
    }
}

// MARK: - Helpers

private extension StorageAnalysisCoordinator {
    static func normalize(_ path: String) -> String {
        StoragePathNormalizer.normalize(path)
    }

    static func containsPath(parent: String, child: String) -> Bool {
        StoragePathNormalizer.contains(parent: parent, child: child)
    }

    static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        StoragePathNormalizer.pathsOverlap(left, right)
    }

    static func candidateOwnershipSort(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftIsUserHome = left.source == .userHomeVisibleStorage
        let rightIsUserHome = right.source == .userHomeVisibleStorage
        if leftIsUserHome != rightIsUserHome { return !leftIsUserHome }
        let leftIsCoverage = left.source == .additionalCoverageGap
        let rightIsCoverage = right.source == .additionalCoverageGap
        if leftIsCoverage != rightIsCoverage { return !leftIsCoverage }
        let leftPath = normalize(left.path)
        let rightPath = normalize(right.path)
        let leftDepth = leftPath.split(separator: "/").count
        let rightDepth = rightPath.split(separator: "/").count
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        if leftPath != rightPath { return leftPath < rightPath }
        return left.source.rawValue < right.source.rawValue
    }

    static func contributionSort(
        _ left: StorageFilesystemContribution,
        _ right: StorageFilesystemContribution
    ) -> Bool {
        if left.source.rawValue != right.source.rawValue {
            return left.source.rawValue < right.source.rawValue
        }
        return left.normalizedPath < right.normalizedPath
    }

    static func rootIndex(_ root: StorageCanonicalRoot) -> Int {
        StorageCanonicalRoot.allCases.firstIndex(of: root) ?? Int.max
    }

    static func accountingSource(for root: StorageCanonicalRoot) -> StorageAccountingSource {
        switch root {
        case .userHomeVisibleStorage: return .userHomeVisibleStorage
        case .applicationSupport: return .applicationSupport
        case .containers: return .containers
        case .groupContainers: return .groupContainers
        case .systemLibrary: return .systemLibrary
        case .privateStorage: return .privateStorage
        case .dataVolumeHiddenStorage: return .dataVolumeHiddenStorage
        case .opt: return .opt
        case .usrLocal: return .usrLocal
        case .additionalCoverageGap: return .additionalCoverageGap
        }
    }

    static func stage(for source: StorageAccountingSource) -> StorageAnalyzerStage {
        switch source {
        case .userHomeVisibleStorage: return .userHomeStorage
        case .applicationSupport: return .applicationSupport
        case .containers: return .containers
        case .groupContainers: return .groupContainers
        case .systemLibrary: return .systemLibrary
        case .privateStorage: return .privateStorage
        case .dataVolumeHiddenStorage: return .dataVolumeHiddenStorage
        case .opt, .usrLocal: return .developerSystemStorage
        case .dockerHostOutsideCanonicalRoots: return .dockerStorage
        case .additionalCoverageGap: return .coverageExpansion
        }
    }

    static func resultsContainCancellation(_ results: StorageAnalyzerResults) -> Bool {
        results.userHomeStorage?.wasCancelled == true
            || results.applicationSupport?.wasCancelled == true
            || results.containers?.wasCancelled == true
            || results.groupContainers?.wasCancelled == true
            || results.systemLibrary?.wasCancelled == true
            || results.privateStorage?.wasCancelled == true
            || results.dataVolumeHiddenStorage?.wasCancelled == true
            || results.developerSystemStorage?.wasCancelled == true
            || results.dockerStorage?.wasCancelled == true
            || results.apfsStorage?.wasCancelled == true
            || results.coverageExpansion?.wasCancelled == true
    }

    static func issueSort(
        _ left: StorageReconciliationIssue,
        _ right: StorageReconciliationIssue
    ) -> Bool {
        if left.kind.rawValue != right.kind.rawValue { return left.kind.rawValue < right.kind.rawValue }
        if left.stage?.rawValue != right.stage?.rawValue {
            return (left.stage?.rawValue ?? "") < (right.stage?.rawValue ?? "")
        }
        if left.path != right.path { return (left.path ?? "") < (right.path ?? "") }
        return left.message < right.message
    }

    static func saturatedAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
