import AppKit
import Combine
import Foundation

enum StorageIntelligenceLifecycle: Equatable {
    case idle
    case running
    case completed
    case cancelled
    case failed
}

enum StorageIntelligenceSortOrder: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sizeDescending: return "Size"
        case .name: return "Name"
        }
    }
}

enum StorageIntelligenceAction: String, CaseIterable, Sendable {
    case analyze
    case cancel
    case search
    case sort
    case navigate
    case revealInFinder
    case permissionGuidance
    case viewDiagnostics
}

enum StorageIntelligenceCategoryID: String, CaseIterable, Identifiable, Sendable {
    case userFiles
    case applicationSupport
    case containers
    case groupContainers
    case systemLibrary
    case privateSystemState
    case hiddenData
    case developerThirdParty
    case docker
    case apfs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userFiles: return "User Files"
        case .applicationSupport: return "Application Support"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .systemLibrary: return "System Library"
        case .privateSystemState: return "Private / System State"
        case .hiddenData: return "Hidden Data"
        case .developerThirdParty: return "Developer & Third-Party"
        case .docker: return "Docker"
        case .apfs: return "APFS / Snapshots"
        }
    }

    var explanation: String {
        switch self {
        case .userFiles: return "Visible files and folders in your home directory."
        case .applicationSupport: return "Application-owned support files and local data."
        case .containers: return "Sandboxed application data stored by macOS."
        case .groupContainers: return "Data shared by related sandboxed applications."
        case .systemLibrary: return "System-wide application and service data in /Library."
        case .privateSystemState: return "Logs, databases, temporary state, and virtual memory under /private."
        case .hiddenData: return "Hidden storage at the top of the writable Data volume."
        case .developerThirdParty: return "Developer tools and third-party installations under /opt and /usr/local."
        case .docker: return "Docker files stored on this Mac, with runtime details kept separate."
        case .apfs: return "Volume capacity and snapshot metadata that is not additive to file totals."
        }
    }
}

struct StorageSummaryPresentation: Equatable, Sendable {
    let totalCapacityBytes: Int64?
    let usedBytes: Int64?
    let freeBytes: Int64?
    let explainedAllocatedBytes: Int64
    let unexplainedBytes: Int64?
    let purgeableEstimateBytes: Int64?

    var usedFraction: Double? {
        guard let totalCapacityBytes, let usedBytes, totalCapacityBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(totalCapacityBytes), 0), 1)
    }

    var explainedFractionOfUsed: Double? {
        guard let usedBytes, usedBytes > 0 else { return nil }
        return min(max(Double(explainedAllocatedBytes) / Double(usedBytes), 0), 1)
    }
}

struct StorageCoveragePresentation: Equatable, Sendable {
    let status: StorageCoverageStatus
    let title: String
    let detail: String
    let isPartial: Bool
    let unreadablePathCount: Int
    let knownLowerBoundBytes: Int64
    let unexplainedBytes: Int64?
    let measurementIssueCount: Int
    let categoryCounts: [StorageCoverageDiagnosticCategoryCount]
}

enum StoragePermissionGuidanceKind: Equatable, Sendable {
    case fullDiskAccessMayHelp
    case permissionDenialsRemainWithFullDiskAccess
}

struct StoragePermissionGuidance: Equatable, Sendable {
    let kind: StoragePermissionGuidanceKind
    let permissionDeniedCount: Int
    let message: String
}

struct StorageCategoryPresentation: Identifiable, Hashable, Sendable {
    let id: StorageIntelligenceCategoryID
    /// Unique bytes this category contributes to reconciliation.
    let allocatedBytes: Int64
    /// Bytes visible in the analyzer's own tree before cross-analyzer ownership.
    let observedAllocatedBytes: Int64
    let roots: [StorageNode]
    let isFilesystemAdditive: Bool
    let issueCount: Int
    let prominentNode: StorageNodePresentation?

    var isOwnedElsewhere: Bool {
        observedAllocatedBytes > 0 && allocatedBytes == 0 && isFilesystemAdditive
    }
}

struct StorageNodePresentation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let absolutePath: String
    let allocatedSize: Int64
    let logicalSize: Int64
    let accessibility: StorageAccessibility
    let storageCategory: String?
    let ownerDisplayName: String?
    let isUnusuallyLarge: Bool
    let isVirtualDisk: Bool
    let isSparseVirtualDisk: Bool
    let hasMaterialLogicalDifference: Bool
    let hasIncompleteMeasurement: Bool
    let issueCount: Int

    init(node: StorageNode) {
        id = node.absolutePath
        name = node.name
        absolutePath = node.absolutePath
        allocatedSize = max(node.allocatedSize, 0)
        logicalSize = max(node.logicalSize, 0)
        accessibility = node.accessibility
        storageCategory = node.metadata.storageCategoryIdentifier
        ownerDisplayName = node.metadata.owningApplicationName
        isUnusuallyLarge = node.metadata.isUnusuallyLarge == true
        isVirtualDisk = Self.virtualDiskExtensions.contains(
            URL(fileURLWithPath: node.absolutePath).pathExtension.lowercased()
        )
        isSparseVirtualDisk = isVirtualDisk && logicalSize > allocatedSize
        hasMaterialLogicalDifference = Self.materiallyDifferent(
            logical: logicalSize,
            allocated: allocatedSize
        )
        hasIncompleteMeasurement = node.accessibility != .accessible || !node.scanIssues.isEmpty
        issueCount = node.scanIssues.count
    }

    private static let virtualDiskExtensions: Set<String> = [
        "img", "raw", "qcow2", "vmdk", "sparsebundle",
    ]

    private static func materiallyDifferent(logical: Int64, allocated: Int64) -> Bool {
        guard logical != allocated else { return false }
        let difference = abs(logical - allocated)
        return difference >= max(1_048_576, max(logical, allocated) / 10)
    }
}

struct StorageSearchResult: Identifiable, Hashable, Sendable {
    let categoryID: StorageIntelligenceCategoryID
    let node: StorageNodePresentation

    var id: String { node.absolutePath }
}

struct StorageDockerRuntimeCategoryPresentation: Identifiable, Equatable, Sendable {
    let category: DockerRuntimeStorageCategory
    let totalBytes: Int64?
    let objectCount: Int?

    var id: String { category.rawValue }

    var title: String {
        switch category {
        case .images: return "Images"
        case .containers: return "Containers"
        case .localVolumes: return "Volumes"
        case .buildCache: return "Build Cache"
        }
    }
}

struct StorageDockerPresentation: Equatable, Sendable {
    let localFootprintBytes: Int64
    let runtimeReportedBytes: Int64?
    let runtimeLocation: DockerRuntimeLocation
    let contextName: String?
    let relationshipMessage: String
    let runtimeIsNonAdditive: Bool
    let runtimeCategories: [StorageDockerRuntimeCategoryPresentation]
}

struct StorageSnapshotPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: APFSSnapshotType
    let creationDate: Date?
    let sizeBytes: Int64?
    let sizeIsReliable: Bool
    let isNonAdditive: Bool
}

struct StorageAPFSPresentation: Equatable, Sendable {
    let filesystemType: String?
    let volumeName: String?
    let totalCapacityBytes: Int64?
    let freeBytes: Int64?
    let purgeableEstimateBytes: Int64?
    let snapshots: [StorageSnapshotPresentation]
    let snapshotsAreNonAdditive: Bool
}

struct StorageAdditionalCoveragePresentation: Equatable, Sendable {
    let totalNewlyMeasuredBytes: Int64
    let measuredRegionCount: Int
    let remainingUnexplainedBytes: Int64?
    let largestDiscoveredRegions: [StorageCoverageCandidate]
    let candidates: [StorageCoverageCandidate]
}

struct StorageAttributionPresentation: Equatable, Sendable {
    let volumeUsedBytes: Int64?
    let explainedAllocatedBytes: Int64
    let unexplainedBytes: Int64?
    let residualUnattributedBytes: Int64?
    let dataVolumeRoots: [DataVolumeRootAttribution]
    let attributionItems: [StorageAttributionItem]
    let vmFootprintBytes: Int64?
    let sleepImageBytes: Int64?
    let snapshotFootprintBytes: Int64?
    let purgeableEstimateBytes: Int64?
}

@MainActor
final class StorageIntelligenceState: ObservableObject {
    typealias ProgressHandler = @Sendable (StorageAnalysisProgress) async -> Void
    typealias AnalysisRunner = @Sendable (_ progress: @escaping ProgressHandler) async throws -> StorageReconciliationReport
    typealias PathExists = @Sendable (_ path: String) -> Bool
    typealias RevealHandler = @MainActor @Sendable (_ path: String) -> Void

    @Published private(set) var lifecycle: StorageIntelligenceLifecycle = .idle
    @Published private(set) var progress: StorageAnalysisProgress?
    @Published private(set) var report: StorageReconciliationReport?
    @Published private(set) var summary: StorageSummaryPresentation?
    @Published private(set) var coverage: StorageCoveragePresentation?
    @Published private(set) var additionalCoverage: StorageAdditionalCoveragePresentation?
    @Published private(set) var attributionPresentation: StorageAttributionPresentation?
    @Published private(set) var coverageDiagnostic: StorageCoverageDiagnostic?
    @Published private(set) var categories: [StorageCategoryPresentation] = []
    @Published private(set) var dockerPresentation: StorageDockerPresentation?
    @Published private(set) var apfsPresentation: StorageAPFSPresentation?
    @Published private(set) var searchText = ""
    @Published private(set) var searchResults: [StorageSearchResult] = []
    @Published private(set) var sortOrder: StorageIntelligenceSortOrder = .sizeDescending
    @Published var selectedCategory: StorageIntelligenceCategoryID?
    @Published var selectedNodePath: String?
    @Published var isShowingDiagnostics = false
    @Published private(set) var errorMessage: String?

    let availableActions: Set<StorageIntelligenceAction> = Set(StorageIntelligenceAction.allCases)

    var isRunning: Bool { lifecycle == .running }
    var canAnalyze: Bool { !isRunning }
    var canCancel: Bool { isRunning }
    var hasCompletedReport: Bool { report != nil }

    private let analysisRunner: AnalysisRunner
    private let pathExists: PathExists
    private let revealHandler: RevealHandler
    private var analysisTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchIndex: [IndexedNode] = []
    private var scanIdentifier = UUID()
    private var presentationIdentifier = UUID()
    private var searchIdentifier = UUID()

    init(
        analysisRunner: @escaping AnalysisRunner = { progress in
            await StorageAnalysisCoordinator().analyze(progress: progress)
        },
        pathExists: @escaping PathExists = { FileManager.default.fileExists(atPath: $0) },
        revealHandler: @escaping RevealHandler = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    ) {
        self.analysisRunner = analysisRunner
        self.pathExists = pathExists
        self.revealHandler = revealHandler
    }

    func analyze() {
        guard !isRunning else { return }
        analysisTask?.cancel()
        preparationTask?.cancel()
        searchTask?.cancel()

        let identifier = UUID()
        scanIdentifier = identifier
        lifecycle = .running
        errorMessage = nil
        progress = StorageAnalysisProgress(
            totalStages: StorageAnalyzerStage.allCases.count,
            completedStages: 0,
            runningStages: [],
            state: .running
        )
        let runner = analysisRunner

        analysisTask = Task { [weak self] in
            do {
                let result = try await runner { update in
                    await MainActor.run {
                        guard let self,
                              self.scanIdentifier == identifier,
                              self.lifecycle == .running else { return }
                        self.progress = update
                    }
                }
                let callerWasCancelled = Task.isCancelled
                let prepared = await Task.detached(priority: .utility) {
                    Self.prepare(report: result, sortOrder: .sizeDescending)
                }.value

                guard let self, self.scanIdentifier == identifier else { return }
                self.apply(result, prepared: prepared)
                self.lifecycle = result.wasCancelled || callerWasCancelled ? .cancelled : .completed
                self.progress = result.progress
            } catch is CancellationError {
                guard let self, self.scanIdentifier == identifier else { return }
                self.lifecycle = .cancelled
                self.progress = Self.cancelledProgress(from: self.progress)
            } catch {
                guard let self, self.scanIdentifier == identifier else { return }
                self.lifecycle = .failed
                self.progress = nil
                self.errorMessage = "Storage analysis could not finish. \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        analysisTask?.cancel()
        lifecycle = .cancelled
        progress = Self.cancelledProgress(from: progress)
    }

    func updateSortOrder(_ order: StorageIntelligenceSortOrder) {
        guard sortOrder != order else { return }
        sortOrder = order
        guard let report else {
            sortSearchResults()
            return
        }

        preparationTask?.cancel()
        let identifier = UUID()
        presentationIdentifier = identifier
        preparationTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                Self.prepare(report: report, sortOrder: order)
            }.value
            guard let self, self.presentationIdentifier == identifier else { return }
            self.applyPresentation(prepared)
        }
    }

    func updateSearch(_ text: String) {
        searchText = text
        scheduleSearch()
    }

    func selectCategory(_ category: StorageIntelligenceCategoryID) {
        selectedCategory = category
        selectedNodePath = nil
    }

    func selectNode(_ node: StorageNodePresentation) {
        selectedNodePath = node.absolutePath
    }

    func showDiagnostics() {
        guard coverageDiagnostic != nil else { return }
        isShowingDiagnostics = true
    }

    func dismissDiagnostics() {
        isShowingDiagnostics = false
    }

    func permissionGuidance(fullDiskAccessGranted: Bool) -> StoragePermissionGuidance? {
        let count = coverageDiagnostic?.permissionDeniedIssueCount ?? 0
        guard count > 0 else { return nil }
        if fullDiskAccessGranted {
            return StoragePermissionGuidance(
                kind: .permissionDenialsRemainWithFullDiskAccess,
                permissionDeniedCount: count,
                message: "macOS denied access to \(count) location\(count == 1 ? "" : "s") even though Full Disk Access is currently detected."
            )
        }
        return StoragePermissionGuidance(
            kind: .fullDiskAccessMayHelp,
            permissionDeniedCount: count,
            message: "macOS denied access to \(count) location\(count == 1 ? "" : "s"). Full Disk Access may improve coverage."
        )
    }

    func canRevealInFinder(_ node: StorageNodePresentation) -> Bool {
        node.accessibility != .skippedDifferentVolume && pathExists(node.absolutePath)
    }

    func revealInFinder(_ node: StorageNodePresentation) {
        guard canRevealInFinder(node) else { return }
        revealHandler(node.absolutePath)
    }

    func waitForAnalysis() async {
        await analysisTask?.value
    }

    func waitForPresentation() async {
        await preparationTask?.value
    }

    func waitForSearch() async {
        await searchTask?.value
    }
}

private extension StorageIntelligenceState {
    struct IndexedNode: Sendable {
        let result: StorageSearchResult
        let searchableText: String
    }

    struct PreparedPresentation: Sendable {
        let summary: StorageSummaryPresentation
        let coverage: StorageCoveragePresentation
        let additionalCoverage: StorageAdditionalCoveragePresentation?
        let attribution: StorageAttributionPresentation?
        let categories: [StorageCategoryPresentation]
        let docker: StorageDockerPresentation?
        let apfs: StorageAPFSPresentation?
        let diagnostic: StorageCoverageDiagnostic
        let searchIndex: [IndexedNode]
    }

    func apply(_ report: StorageReconciliationReport, prepared: PreparedPresentation) {
        self.report = report
        sortOrder = .sizeDescending
        applyPresentation(prepared)
    }

    func applyPresentation(_ prepared: PreparedPresentation) {
        summary = prepared.summary
        coverage = prepared.coverage
        additionalCoverage = prepared.additionalCoverage
        attributionPresentation = prepared.attribution
        coverageDiagnostic = prepared.diagnostic
        categories = prepared.categories
        dockerPresentation = prepared.docker
        apfsPresentation = prepared.apfs
        searchIndex = prepared.searchIndex
        scheduleSearch()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        let index = searchIndex
        let order = sortOrder
        let identifier = UUID()
        searchIdentifier = identifier
        searchTask = Task { [weak self] in
            let matches = await Task.detached(priority: .utility) {
                index
                    .filter { $0.searchableText.contains(query) }
                    .map(\.result)
                    .sorted { Self.searchSort($0, $1, order: order) }
            }.value
            guard let self, self.searchIdentifier == identifier else { return }
            self.searchResults = matches
        }
    }

    func sortSearchResults() {
        searchResults.sort { Self.searchSort($0, $1, order: sortOrder) }
    }

    nonisolated static func prepare(
        report: StorageReconciliationReport,
        sortOrder: StorageIntelligenceSortOrder
    ) -> PreparedPresentation {
        let summary = StorageSummaryPresentation(
            totalCapacityBytes: report.totalCapacityBytes,
            usedBytes: report.usedCapacityBytes,
            freeBytes: report.availableCapacityBytes,
            explainedAllocatedBytes: max(report.explainedAllocatedBytes, 0),
            unexplainedBytes: report.unexplainedBytes,
            purgeableEstimateBytes: report.purgeableEstimateBytes
        )
        let coverage = coveragePresentation(report)
        let additionalCoverage: StorageAdditionalCoveragePresentation?
        if let expansion = report.analyzerResults.coverageExpansion,
           !expansion.candidates.isEmpty || expansion.totalNewlyMeasuredBytes > 0 {
            additionalCoverage = StorageAdditionalCoveragePresentation(
                totalNewlyMeasuredBytes: expansion.totalNewlyMeasuredBytes,
                measuredRegionCount: expansion.measuredCandidateCount,
                remainingUnexplainedBytes: report.unexplainedBytes,
                largestDiscoveredRegions: expansion.largestDiscoveredRegions,
                candidates: expansion.candidates
            )
        } else {
            additionalCoverage = nil
        }
        let attributionPresentation: StorageAttributionPresentation?
        if let attr = report.attributionReport {
            attributionPresentation = StorageAttributionPresentation(
                volumeUsedBytes: attr.volumeUsedBytes,
                explainedAllocatedBytes: attr.explainedAllocatedBytes,
                unexplainedBytes: attr.unexplainedBytes,
                residualUnattributedBytes: attr.residualUnattributedBytes,
                dataVolumeRoots: attr.dataVolumeRoots,
                attributionItems: attr.attributionItems,
                vmFootprintBytes: attr.vmFootprintBytes,
                sleepImageBytes: attr.sleepImageBytes,
                snapshotFootprintBytes: attr.snapshotFootprintBytes,
                purgeableEstimateBytes: attr.purgeableEstimateBytes
            )
        } else {
            attributionPresentation = nil
        }
        let unsortedCategories = makeCategories(report)
        let categories = unsortedCategories
            .map { category in
                StorageCategoryPresentation(
                    id: category.id,
                    allocatedBytes: category.allocatedBytes,
                    observedAllocatedBytes: category.observedAllocatedBytes,
                    roots: category.roots
                        .map { sortedTree($0, order: sortOrder) }
                        .sorted { nodeSort($0, $1, order: sortOrder) },
                    isFilesystemAdditive: category.isFilesystemAdditive,
                    issueCount: category.issueCount,
                    prominentNode: category.prominentNode
                )
            }
            .sorted(by: categorySort)
        return PreparedPresentation(
            summary: summary,
            coverage: coverage,
            additionalCoverage: additionalCoverage,
            attribution: attributionPresentation,
            categories: categories,
            docker: dockerPresentation(report.analyzerResults.dockerStorage),
            apfs: apfsPresentation(report.analyzerResults.apfsStorage),
            diagnostic: report.coverageDiagnostic,
            searchIndex: makeSearchIndex(categories)
        )
    }

    nonisolated static func coveragePresentation(
        _ report: StorageReconciliationReport
    ) -> StorageCoveragePresentation {
        let title: String
        let reason: String
        switch report.coverageStatus {
        case .completeForConfiguredRoots:
            title = "Complete for configured locations"
            reason = report.incompleteCoverage
                ? "Configured locations were measured, but APFS and inaccessible edge storage may remain unattributed."
                : "All configured locations were measured."
        case .partialDueToPermissions:
            title = "Partial due to permissions"
            reason = "macOS denied access to one or more measured locations."
        case .partialDueToMeasurementIssues:
            title = "Partial due to measurement issues"
            reason = "Some locations could not be fully measured for non-permission reasons."
        case .partialDueToCancellation:
            title = "Partial because analysis was cancelled"
            reason = "Displayed values include only locations measured before cancellation."
        case .partialDueToAnalyzerFailure:
            title = "Partial due to analyzer errors"
            reason = "One or more storage sources failed, while successful results were preserved."
        }
        let unreadable = report.unreadablePathCount
        let detail = unreadable > 0
            ? "\(reason) \(unreadable) location\(unreadable == 1 ? "" : "s") could not be fully read."
            : reason
        return StorageCoveragePresentation(
            status: report.coverageStatus,
            title: title,
            detail: detail,
            isPartial: report.coverageStatus != .completeForConfiguredRoots,
            unreadablePathCount: unreadable,
            knownLowerBoundBytes: max(report.inaccessibleKnownLowerBoundBytes, 0),
            unexplainedBytes: report.unexplainedBytes,
            measurementIssueCount: report.coverageDiagnostic.measurementIssues.totalIssueCount,
            categoryCounts: report.coverageDiagnostic.measurementIssues.categoryCounts
        )
    }

    nonisolated static func makeCategories(
        _ report: StorageReconciliationReport
    ) -> [StorageCategoryPresentation] {
        let results = report.analyzerResults
        let contributions = report.filesystemContributions

        func accounted(_ sources: Set<StorageAccountingSource>) -> Int64 {
            contributions
                .filter { sources.contains($0.source) }
                .reduce(Int64(0)) { saturatedAdd($0, max($1.accountedAllocatedBytes, 0)) }
        }

        func issueCount(_ result: StorageAnalysisResult?) -> Int {
            result?.issues.count ?? 0
        }

        func category(
            _ id: StorageIntelligenceCategoryID,
            sources: Set<StorageAccountingSource>,
            observed: Int64,
            roots: [StorageNode],
            issues: Int,
            additive: Bool = true
        ) -> StorageCategoryPresentation {
            let prominent = roots
                .flatMap { [$0] + $0.children }
                .map(StorageNodePresentation.init)
                .filter(\.isUnusuallyLarge)
                .max { $0.allocatedSize < $1.allocatedSize }
            return StorageCategoryPresentation(
                id: id,
                allocatedBytes: additive ? accounted(sources) : 0,
                observedAllocatedBytes: max(observed, 0),
                roots: roots,
                isFilesystemAdditive: additive,
                issueCount: issues,
                prominentNode: prominent
            )
        }

        let userRoots = results.userHomeStorage?.roots.map(\.node) ?? []
        let applicationRoots = results.applicationSupport?.root.children ?? []
        let containerRoots = results.containers?.root.children ?? []
        let groupRoots = results.groupContainers?.root.children ?? []
        let libraryRoots = results.systemLibrary?.root.children ?? []
        let privateRoots = results.privateStorage?.root.children ?? []
        let hiddenRoots = results.dataVolumeHiddenStorage?.root.children ?? []
        let developerRoots = [
            results.developerSystemStorage?.opt.result.root,
            results.developerSystemStorage?.usrLocal.result.root,
        ].compactMap { $0 }
        let dockerRoots = results.dockerStorage?.hostFootprint.locations.map(\.root) ?? []

        return [
            category(
                .userFiles,
                sources: [.userHomeVisibleStorage],
                observed: results.userHomeStorage?.combinedUniqueAllocatedSize ?? 0,
                roots: userRoots,
                issues: results.userHomeStorage?.issues.count ?? 0
            ),
            category(
                .applicationSupport,
                sources: [.applicationSupport],
                observed: results.applicationSupport?.root.allocatedSize ?? 0,
                roots: applicationRoots,
                issues: issueCount(results.applicationSupport)
            ),
            category(
                .containers,
                sources: [.containers],
                observed: results.containers?.root.allocatedSize ?? 0,
                roots: containerRoots,
                issues: issueCount(results.containers)
            ),
            category(
                .groupContainers,
                sources: [.groupContainers],
                observed: results.groupContainers?.root.allocatedSize ?? 0,
                roots: groupRoots,
                issues: issueCount(results.groupContainers)
            ),
            category(
                .systemLibrary,
                sources: [.systemLibrary],
                observed: results.systemLibrary?.root.allocatedSize ?? 0,
                roots: libraryRoots,
                issues: issueCount(results.systemLibrary)
            ),
            category(
                .privateSystemState,
                sources: [.privateStorage],
                observed: results.privateStorage?.root.allocatedSize ?? 0,
                roots: privateRoots,
                issues: issueCount(results.privateStorage)
            ),
            category(
                .hiddenData,
                sources: [.dataVolumeHiddenStorage],
                observed: results.dataVolumeHiddenStorage?.root.allocatedSize ?? 0,
                roots: hiddenRoots,
                issues: issueCount(results.dataVolumeHiddenStorage)
            ),
            category(
                .developerThirdParty,
                sources: [.opt, .usrLocal],
                observed: results.developerSystemStorage?.combinedUniqueAllocatedSize ?? 0,
                roots: developerRoots,
                issues: results.developerSystemStorage?.issues.count ?? 0
            ),
            category(
                .docker,
                sources: [.dockerHostOutsideCanonicalRoots],
                observed: results.dockerStorage?.hostFootprint.allocatedSize ?? 0,
                roots: dockerRoots,
                issues: results.dockerStorage?.issues.count ?? 0
            ),
            category(
                .apfs,
                sources: [],
                observed: 0,
                roots: [],
                issues: results.apfsStorage?.issues.count ?? 0,
                additive: false
            ),
        ]
    }

    nonisolated static func dockerPresentation(_ report: DockerStorageReport?) -> StorageDockerPresentation? {
        guard let report else { return nil }
        let message: String
        switch report.hostRuntimeRelationship {
        case .localRuntimeMayExplainHostFootprint:
            message = "Local Docker runtime details may explain the host files below, but are not added again."
        case .remoteRuntimeNotRelatedToHostFootprint:
            message = "Remote Docker context. Runtime storage is not stored on this Mac."
        case .unknownRelationship:
            message = "Docker runtime location is unknown, so runtime values are kept separate from this Mac."
        }
        return StorageDockerPresentation(
            localFootprintBytes: max(report.macDiskUsageBytes, 0),
            runtimeReportedBytes: report.totalRuntimeReportedBytes,
            runtimeLocation: report.runtimeContext.location,
            contextName: report.runtimeContext.name,
            relationshipMessage: message,
            runtimeIsNonAdditive: true,
            runtimeCategories: report.runtimeAccounting?.categories.map {
                StorageDockerRuntimeCategoryPresentation(
                    category: $0.category,
                    totalBytes: $0.totalBytes,
                    objectCount: $0.objectCount
                )
            } ?? []
        )
    }

    nonisolated static func apfsPresentation(_ report: APFSStorageReport?) -> StorageAPFSPresentation? {
        guard let report else { return nil }
        return StorageAPFSPresentation(
            filesystemType: report.volume.filesystemType,
            volumeName: report.volume.name,
            totalCapacityBytes: report.volume.capacity.totalCapacity,
            freeBytes: report.volume.capacity.availableCapacity,
            purgeableEstimateBytes: report.volume.capacity.purgeableEstimate,
            snapshots: report.snapshots.map {
                StorageSnapshotPresentation(
                    id: $0.identifier,
                    name: $0.name ?? $0.identifier,
                    type: $0.type,
                    creationDate: $0.creationDate,
                    sizeBytes: $0.sizeKnowledge == .reportedBySystem ? $0.size : nil,
                    sizeIsReliable: $0.sizeKnowledge == .reportedBySystem && $0.size != nil,
                    isNonAdditive: true
                )
            },
            snapshotsAreNonAdditive: true
        )
    }

    nonisolated static func makeSearchIndex(
        _ categories: [StorageCategoryPresentation]
    ) -> [IndexedNode] {
        var index: [IndexedNode] = []
        var seenPaths: Set<String> = []
        for category in categories where !category.roots.isEmpty {
            var pending = category.roots
            while let node = pending.popLast() {
                pending.append(contentsOf: node.children)
                guard seenPaths.insert(node.absolutePath).inserted else { continue }
                let presentation = StorageNodePresentation(node: node)
                let text = [
                    presentation.name,
                    presentation.absolutePath,
                    presentation.ownerDisplayName ?? "",
                ].joined(separator: "\n").lowercased()
                index.append(IndexedNode(
                    result: StorageSearchResult(categoryID: category.id, node: presentation),
                    searchableText: text
                ))
            }
        }
        return index
    }

    nonisolated static func sortedTree(
        _ node: StorageNode,
        order: StorageIntelligenceSortOrder
    ) -> StorageNode {
        let children = node.children
            .map { sortedTree($0, order: order) }
            .sorted { nodeSort($0, $1, order: order) }
        return StorageNode(
            name: node.name,
            absolutePath: node.absolutePath,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            ownLogicalSize: node.ownLogicalSize,
            ownAllocatedSize: node.ownAllocatedSize,
            itemType: node.itemType,
            children: children,
            accessibility: node.accessibility,
            scanIssues: node.scanIssues,
            isHidden: node.isHidden,
            isSymbolicLink: node.isSymbolicLink,
            isCountedInParentTotals: node.isCountedInParentTotals,
            metadata: node.metadata
        )
    }

    nonisolated static func nodeSort(
        _ left: StorageNode,
        _ right: StorageNode,
        order: StorageIntelligenceSortOrder
    ) -> Bool {
        switch order {
        case .sizeDescending:
            if left.allocatedSize != right.allocatedSize {
                return left.allocatedSize > right.allocatedSize
            }
        case .name:
            let comparison = left.name.localizedStandardCompare(right.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return left.absolutePath < right.absolutePath
    }

    nonisolated static func categorySort(
        _ left: StorageCategoryPresentation,
        _ right: StorageCategoryPresentation
    ) -> Bool {
        if left.isFilesystemAdditive != right.isFilesystemAdditive {
            return left.isFilesystemAdditive
        }
        if left.allocatedBytes != right.allocatedBytes {
            return left.allocatedBytes > right.allocatedBytes
        }
        return left.id.title < right.id.title
    }

    nonisolated static func searchSort(
        _ left: StorageSearchResult,
        _ right: StorageSearchResult,
        order: StorageIntelligenceSortOrder
    ) -> Bool {
        switch order {
        case .sizeDescending:
            if left.node.allocatedSize != right.node.allocatedSize {
                return left.node.allocatedSize > right.node.allocatedSize
            }
        case .name:
            let comparison = left.node.name.localizedStandardCompare(right.node.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return left.node.absolutePath < right.node.absolutePath
    }

    nonisolated static func cancelledProgress(
        from progress: StorageAnalysisProgress?
    ) -> StorageAnalysisProgress {
        StorageAnalysisProgress(
            totalStages: progress?.totalStages ?? StorageAnalyzerStage.allCases.count,
            completedStages: progress?.completedStages ?? 0,
            runningStages: [],
            state: .cancelled
        )
    }

    nonisolated static func saturatedAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}
