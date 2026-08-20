import Foundation

/// The existing read-only analyzer stages coordinated by whole-disk
/// reconciliation. Raw values provide stable deterministic ordering.
enum StorageAnalyzerStage: String, Codable, CaseIterable, Sendable {
    case apfsVolume
    case userHomeStorage
    case applications
    case applicationSupport
    case containers
    case groupContainers
    case systemLibrary
    case privateStorage
    case dataVolumeHiddenStorage
    case developerSystemStorage
    case dockerStorage
    case coverageExpansion
}

enum StorageCoordinatorRunState: String, Codable, Sendable {
    case running
    case completed
    case cancelled
}

struct StorageAnalysisProgress: Hashable, Codable, Sendable {
    let totalStages: Int
    let completedStages: Int
    let runningStages: [StorageAnalyzerStage]
    let state: StorageCoordinatorRunState
}

enum StorageCoverageStatus: String, Codable, Sendable {
    case completeForConfiguredRoots
    case partialDueToPermissions
    case partialDueToMeasurementIssues
    case partialDueToCancellation
    case partialDueToAnalyzerFailure
}

enum StorageCanonicalRoot: String, Codable, CaseIterable, Sendable {
    case userHomeVisibleStorage
    case applications
    case applicationSupport
    case containers
    case groupContainers
    case systemLibrary
    case privateStorage
    case dataVolumeHiddenStorage
    case opt
    case usrLocal
    case additionalCoverageGap
}

enum StorageCanonicalRootState: String, Codable, Sendable {
    case completed
    case partiallyCompleted
    case failed
    case missingOptional
    case cancelled
}

struct StorageCanonicalRootCoverage: Hashable, Codable, Sendable {
    let root: StorageCanonicalRoot
    let configuredPath: String
    let state: StorageCanonicalRootState
    /// Successfully measured bytes. For partial roots this is a known lower
    /// bound and never an estimate of unreadable descendants.
    let knownAllocatedBytes: Int64
    let unreadablePathCount: Int
}

enum StorageAccountingSource: String, Codable, Sendable {
    case userHomeVisibleStorage
    case applications
    case applicationSupport
    case containers
    case groupContainers
    case systemLibrary
    case privateStorage
    case dataVolumeHiddenStorage
    case opt
    case usrLocal
    case dockerHostOutsideCanonicalRoots
    case additionalCoverageGap
}

enum StorageContributionRelationship: String, Codable, Sendable {
    case canonicalUnique
    case externalSpecializedUnique
    case excludedDuplicatePath
    case excludedNestedPath
}

/// One path considered by the canonical ownership policy. Observed bytes are
/// retained even when ownership assigns them to another enclosing root.
struct StorageFilesystemContribution: Hashable, Codable, Sendable {
    let source: StorageAccountingSource
    let absolutePath: String
    let normalizedPath: String
    let observedAllocatedBytes: Int64
    let accountedAllocatedBytes: Int64
    let relationship: StorageContributionRelationship
    let owningPath: String?
}

enum StorageHardLinkAccountingStatus: String, Codable, Sendable {
    /// Each analyzer tree deduplicates internally and the developer analyzer
    /// shares a ledger across /opt and /usr/local. Independent analyzer trees
    /// currently do not expose inode identity for a global post-scan ledger.
    case deduplicatedWithinAnalyzerScopesOnly
}

enum StorageReconciliationIssueKind: String, Codable, Sendable {
    case analyzerFailure
    case analyzerIssue
    case permissionIncomplete
    case cancelled
    case duplicateRootExcluded
    case nestedRootExcluded
    case accountingAnomaly
    case crossAnalyzerHardLinkDeduplicationUnavailable
}

struct StorageReconciliationIssue: Identifiable, Hashable, Codable, Sendable {
    let kind: StorageReconciliationIssueKind
    let stage: StorageAnalyzerStage?
    let path: String?
    let message: String

    var id: String {
        "\(kind.rawValue)|\(stage?.rawValue ?? "")|\(path ?? "")|\(message)"
    }
}

enum StorageCoverageCandidateScope: String, Codable, Sendable {
    case userLibrary
    case hiddenHome
    case dataVolumeRoot
    case other
}

enum StorageCoverageCandidateStatus: String, Codable, Sendable {
    case eligible
    case measured
    case partiallyMeasured
    case inaccessible
    case skippedAlreadyOwned
    case skippedNonAdditive
    case skippedUnsafeOverlap
    case excludedAlreadyAccounted
    case excludedNested
    case excludedSymlink
    case excludedDifferentVolume
    case excludedProtectedSystem
    case failed
    case cancelled

    var isMeasuredOrPartial: Bool {
        self == .measured || self == .partiallyMeasured
    }

    var displayName: String {
        switch self {
        case .eligible: return "Eligible"
        case .measured: return "Measured"
        case .partiallyMeasured: return "Partial"
        case .inaccessible: return "Inaccessible"
        case .skippedAlreadyOwned, .excludedAlreadyAccounted: return "Already Accounted"
        case .skippedNonAdditive: return "Non-additive"
        case .skippedUnsafeOverlap, .excludedNested: return "Excluded (Overlap)"
        case .excludedSymlink: return "Excluded (Symlink)"
        case .excludedDifferentVolume: return "Different Volume"
        case .excludedProtectedSystem: return "Protected System"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct StorageCoverageCandidate: Identifiable, Hashable, Codable, Sendable {
    let originalPath: String
    let normalizedPath: String
    let name: String
    let scope: StorageCoverageCandidateScope
    let status: StorageCoverageCandidateStatus
    let allocatedBytes: Int64?
    let logicalBytes: Int64?
    let issue: StorageScanIssue?
    let exclusionReason: String?
    let contributesToExplainedBytes: Bool

    var id: String { normalizedPath }
}

struct StorageCoverageExpansionReport: Hashable, Codable, Sendable {
    let totalNewlyMeasuredBytes: Int64
    let measuredCandidateCount: Int
    let excludedOverlapCount: Int
    let inaccessibleCandidateCount: Int
    let differentVolumeBoundaryCount: Int
    let failedCandidateCount: Int
    let candidates: [StorageCoverageCandidate]
    let largestDiscoveredRegions: [StorageCoverageCandidate]
    let treeResults: [StorageAnalysisResult]
    let wasCancelled: Bool
    let issues: [StorageScanIssue]

    static let empty = StorageCoverageExpansionReport(
        totalNewlyMeasuredBytes: 0,
        measuredCandidateCount: 0,
        excludedOverlapCount: 0,
        inaccessibleCandidateCount: 0,
        differentVolumeBoundaryCount: 0,
        failedCandidateCount: 0,
        candidates: [],
        largestDiscoveredRegions: [],
        treeResults: [],
        wasCancelled: false,
        issues: []
    )
}

/// Every underlying result remains available as explanatory drill-down data.
/// Optional values indicate a stage that failed or never started.
struct StorageAnalyzerResults: Hashable, Codable, Sendable {
    var userHomeStorage: UserHomeStorageReport?
    var applications: StorageAnalysisResult?
    var applicationSupport: StorageAnalysisResult?
    var containers: StorageAnalysisResult?
    var groupContainers: StorageAnalysisResult?
    var systemLibrary: StorageAnalysisResult?
    var privateStorage: StorageAnalysisResult?
    var dataVolumeHiddenStorage: StorageAnalysisResult?
    var developerSystemStorage: DeveloperSystemStorageReport?
    var dockerStorage: DockerStorageReport?
    var apfsStorage: APFSStorageReport?
    var coverageExpansion: StorageCoverageExpansionReport?
    var physicalReconciliation: APFSPhysicalReconciliationReport?

    init(
        userHomeStorage: UserHomeStorageReport? = nil,
        applications: StorageAnalysisResult? = nil,
        applicationSupport: StorageAnalysisResult? = nil,
        containers: StorageAnalysisResult? = nil,
        groupContainers: StorageAnalysisResult? = nil,
        systemLibrary: StorageAnalysisResult? = nil,
        privateStorage: StorageAnalysisResult? = nil,
        dataVolumeHiddenStorage: StorageAnalysisResult? = nil,
        developerSystemStorage: DeveloperSystemStorageReport? = nil,
        dockerStorage: DockerStorageReport? = nil,
        apfsStorage: APFSStorageReport? = nil,
        coverageExpansion: StorageCoverageExpansionReport? = nil,
        physicalReconciliation: APFSPhysicalReconciliationReport? = nil
    ) {
        self.userHomeStorage = userHomeStorage
        self.applications = applications
        self.applicationSupport = applicationSupport
        self.containers = containers
        self.groupContainers = groupContainers
        self.systemLibrary = systemLibrary
        self.privateStorage = privateStorage
        self.dataVolumeHiddenStorage = dataVolumeHiddenStorage
        self.developerSystemStorage = developerSystemStorage
        self.dockerStorage = dockerStorage
        self.apfsStorage = apfsStorage
        self.coverageExpansion = coverageExpansion
        self.physicalReconciliation = physicalReconciliation
    }
}

struct StorageReconciliationReport: Hashable, Codable, Sendable {
    let totalCapacityBytes: Int64?
    let usedCapacityBytes: Int64?
    let availableCapacityBytes: Int64?
    /// An OS-provided estimate kept separate from both used and explained
    /// bytes. It is not guaranteed reclaimable capacity.
    let purgeableEstimateBytes: Int64?

    /// Unique allocated filesystem bytes attributed by the configured roots
    /// under the coordinator's ownership policy.
    let explainedAllocatedBytes: Int64
    /// `max(used - explained, 0)` when used capacity is known. This includes
    /// uncovered roots, inaccessible descendants, APFS metadata/shared
    /// extents, and current accounting limitations; it is never called junk.
    let unexplainedBytes: Int64?
    /// The measured subset of partial/inaccessible roots. This is contained
    /// in explained bytes and does not estimate the unreadable remainder.
    let inaccessibleKnownLowerBoundBytes: Int64
    let unreadablePathCount: Int

    /// True because configured analyzers still cannot fully observe every
    /// volume path, inaccessible descendant, or APFS shared extent.
    let incompleteCoverage: Bool
    let coverageStatus: StorageCoverageStatus
    let canonicalRootCoverage: [StorageCanonicalRootCoverage]
    let filesystemContributions: [StorageFilesystemContribution]
    let hardLinkAccountingStatus: StorageHardLinkAccountingStatus
    let analysisIssues: [StorageReconciliationIssue]
    let analyzerResults: StorageAnalyzerResults
    /// Read-only explanation of incomplete measurement and intentionally
    /// uncovered regions. It does not contribute any storage bytes.
    let coverageDiagnostic: StorageCoverageDiagnostic
    /// Typed attribution breakdown explaining why unexplained storage remains.
    let attributionReport: StorageUnexplainedAttributionReport?
    /// Physical reconciliation report bridging container/volume usage to filesystem accounting.
    let physicalReconciliation: APFSPhysicalReconciliationReport?

    let startedAt: Date
    let completedAt: Date
    let duration: TimeInterval
    let progress: StorageAnalysisProgress
    let wasCancelled: Bool

    init(
        totalCapacityBytes: Int64?,
        usedCapacityBytes: Int64?,
        availableCapacityBytes: Int64?,
        purgeableEstimateBytes: Int64?,
        explainedAllocatedBytes: Int64,
        unexplainedBytes: Int64?,
        inaccessibleKnownLowerBoundBytes: Int64,
        unreadablePathCount: Int,
        incompleteCoverage: Bool,
        coverageStatus: StorageCoverageStatus,
        canonicalRootCoverage: [StorageCanonicalRootCoverage],
        filesystemContributions: [StorageFilesystemContribution],
        hardLinkAccountingStatus: StorageHardLinkAccountingStatus,
        analysisIssues: [StorageReconciliationIssue],
        analyzerResults: StorageAnalyzerResults,
        coverageDiagnostic: StorageCoverageDiagnostic,
        attributionReport: StorageUnexplainedAttributionReport? = nil,
        physicalReconciliation: APFSPhysicalReconciliationReport? = nil,
        startedAt: Date,
        completedAt: Date,
        duration: TimeInterval,
        progress: StorageAnalysisProgress,
        wasCancelled: Bool
    ) {
        self.totalCapacityBytes = totalCapacityBytes
        self.usedCapacityBytes = usedCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
        self.purgeableEstimateBytes = purgeableEstimateBytes
        self.explainedAllocatedBytes = explainedAllocatedBytes
        self.unexplainedBytes = unexplainedBytes
        self.inaccessibleKnownLowerBoundBytes = inaccessibleKnownLowerBoundBytes
        self.unreadablePathCount = unreadablePathCount
        self.incompleteCoverage = incompleteCoverage
        self.coverageStatus = coverageStatus
        self.canonicalRootCoverage = canonicalRootCoverage
        self.filesystemContributions = filesystemContributions
        self.hardLinkAccountingStatus = hardLinkAccountingStatus
        self.analysisIssues = analysisIssues
        self.analyzerResults = analyzerResults
        self.coverageDiagnostic = coverageDiagnostic
        self.attributionReport = attributionReport
        self.physicalReconciliation = physicalReconciliation
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
        self.progress = progress
        self.wasCancelled = wasCancelled
    }
}
