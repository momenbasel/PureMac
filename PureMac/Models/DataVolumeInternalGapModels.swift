import Foundation

/// Strict 5-tier classification for Data-volume accounting evidence.
enum DataVolumeGapEvidenceTier: String, Codable, CaseIterable, Sendable {
    /// Reliable exclusive filesystem allocation that can participate in byte accounting.
    case measuredAdditive
    /// Reliable measurement exists, but may overlap existing filesystem or APFS blocks.
    case measuredNonAdditive
    /// macOS reports a value (e.g. Purgeable estimate) but it cannot safely be treated as exclusive physical allocation.
    case estimatedOSReported
    /// Storage mechanism is confirmed to exist, but exclusive physical bytes cannot be determined from userland APIs.
    case presenceOnly
    /// Inaccessible SIP/TCC restricted locations where bytes cannot be measured.
    case unknownProtected

    var displayName: String {
        switch self {
        case .measuredAdditive: return "Additive"
        case .measuredNonAdditive: return "Non-additive"
        case .estimatedOSReported: return "Estimate"
        case .presenceOnly: return "Presence-only"
        case .unknownProtected: return "Protected"
        }
    }
}

/// Categorization of evidence items explaining the Data-volume internal gap.
enum DataVolumeGapEvidenceCategory: String, Codable, CaseIterable, Sendable {
    case filesystemAllocationDelta
    case purgeableEstimate
    case protectedStorage
    case apfsSnapshots
    case cloneSharedExtents
    case apfsFilesystemMetadata
    case unresolvedResidual

    var displayName: String {
        switch self {
        case .filesystemAllocationDelta: return "Allocation vs Logical Size Delta"
        case .purgeableEstimate: return "Purgeable Capacity Estimate"
        case .protectedStorage: return "Protected & Inaccessible Locations"
        case .apfsSnapshots: return "APFS Snapshots & Extents"
        case .cloneSharedExtents: return "APFS Clones & Shared Extents"
        case .apfsFilesystemMetadata: return "APFS Metadata & Structure Overhead"
        case .unresolvedResidual: return "Unresolved Physical Accounting Delta"
        }
    }
}

/// An individual row in the Data Volume Internal Gap Waterfall.
struct DataVolumeGapWaterfallItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let category: DataVolumeGapEvidenceCategory
    let tier: DataVolumeGapEvidenceTier
    let reportedBytes: Int64?
    let explanation: String
    let badgeText: String

    init(
        id: String,
        title: String,
        category: DataVolumeGapEvidenceCategory,
        tier: DataVolumeGapEvidenceTier,
        reportedBytes: Int64?,
        explanation: String,
        badgeText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.tier = tier
        self.reportedBytes = reportedBytes
        self.explanation = explanation
        self.badgeText = badgeText ?? tier.displayName
    }
}

/// A grouped family of macOS-protected / SIP / TCC inaccessible locations.
struct DataVolumeProtectedFamily: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let pathPattern: String
    let issueCount: Int
    let knownLowerBoundBytes: Int64?
    let explanation: String

    init(
        id: String,
        name: String,
        pathPattern: String,
        issueCount: Int,
        knownLowerBoundBytes: Int64?,
        explanation: String
    ) {
        self.id = id
        self.name = name
        self.pathPattern = pathPattern
        self.issueCount = issueCount
        self.knownLowerBoundBytes = knownLowerBoundBytes
        self.explanation = explanation
    }
}

/// Aggregated summary of protected and restricted storage across the Data volume.
struct DataVolumeProtectedStorageSummary: Hashable, Codable, Sendable {
    let families: [DataVolumeProtectedFamily]
    let totalProtectedIssueCount: Int
    let inaccessiblePathCount: Int
    let knownLowerBoundBytes: Int64
    let explanation: String

    init(
        families: [DataVolumeProtectedFamily],
        totalProtectedIssueCount: Int,
        inaccessiblePathCount: Int,
        knownLowerBoundBytes: Int64,
        explanation: String
    ) {
        self.families = families
        self.totalProtectedIssueCount = totalProtectedIssueCount
        self.inaccessiblePathCount = inaccessiblePathCount
        self.knownLowerBoundBytes = knownLowerBoundBytes
        self.explanation = explanation
    }

    static let empty = DataVolumeProtectedStorageSummary(
        families: [],
        totalProtectedIssueCount: 0,
        inaccessiblePathCount: 0,
        knownLowerBoundBytes: 0,
        explanation: "No macOS protected system access barriers recorded."
    )
}

/// Comparison between logical bytes (st_size) and physical allocated blocks (st_blocks * 512).
struct DataVolumeAllocationDeltaSummary: Hashable, Codable, Sendable {
    let totalMeasuredLogicalBytes: Int64
    let totalMeasuredAllocatedBytes: Int64
    /// `totalMeasuredAllocatedBytes - totalMeasuredLogicalBytes`
    let deltaBytes: Int64
    let sparseFilesObserved: Bool
    let blockPaddingObserved: Bool
    let explanation: String

    init(
        totalMeasuredLogicalBytes: Int64,
        totalMeasuredAllocatedBytes: Int64,
        deltaBytes: Int64,
        sparseFilesObserved: Bool,
        blockPaddingObserved: Bool,
        explanation: String
    ) {
        self.totalMeasuredLogicalBytes = totalMeasuredLogicalBytes
        self.totalMeasuredAllocatedBytes = totalMeasuredAllocatedBytes
        self.deltaBytes = deltaBytes
        self.sparseFilesObserved = sparseFilesObserved
        self.blockPaddingObserved = blockPaddingObserved
        self.explanation = explanation
    }

    static let empty = DataVolumeAllocationDeltaSummary(
        totalMeasuredLogicalBytes: 0,
        totalMeasuredAllocatedBytes: 0,
        deltaBytes: 0,
        sparseFilesObserved: false,
        blockPaddingObserved: false,
        explanation: "Allocation-to-logical size comparison is unavailable."
    )
}

/// Comprehensive report deconstructing the Data-volume internal gap (~46.41 GB).
struct DataVolumeInternalGapReport: Hashable, Codable, Sendable {
    /// Physical allocation reported by APFS for the Data volume (e.g. 189.65 GB).
    let dataVolumePhysicalInUseBytes: Int64?
    /// Unique filesystem allocated blocks attributed by PureMac scanners (e.g. 143.24 GB).
    let filesystemAttributedBytes: Int64
    /// Internal accounting gap: `max(dataVolumePhysicalInUseBytes - filesystemAttributedBytes, 0)` (~46.41 GB).
    let internalPhysicalGapBytes: Int64?

    /// Logical vs physical allocated block diagnostic.
    let allocationDeltaSummary: DataVolumeAllocationDeltaSummary
    /// Waterfall rows deconstructing the gap.
    let waterfallItems: [DataVolumeGapWaterfallItem]
    /// Protected storage aggregated families.
    let protectedSummary: DataVolumeProtectedStorageSummary

    /// Total bytes justified by MEASURED ADDITIVE evidence (strictly 0 GB unless exclusive).
    let additiveExplainedPortionBytes: Int64
    /// Total bytes supported by non-additive, estimated, or presence-only evidence.
    let nonAdditiveEvidencedPortionBytes: Int64
    /// Unresolved residual gap: `internalPhysicalGapBytes - additiveExplainedPortionBytes`.
    let unresolvedResidualGapBytes: Int64?

    let humanReadableInterpretation: String
    let wasCancelled: Bool
    let issues: [APFSStorageIssue]

    init(
        dataVolumePhysicalInUseBytes: Int64?,
        filesystemAttributedBytes: Int64,
        internalPhysicalGapBytes: Int64?,
        allocationDeltaSummary: DataVolumeAllocationDeltaSummary,
        waterfallItems: [DataVolumeGapWaterfallItem],
        protectedSummary: DataVolumeProtectedStorageSummary,
        additiveExplainedPortionBytes: Int64 = 0,
        nonAdditiveEvidencedPortionBytes: Int64,
        unresolvedResidualGapBytes: Int64?,
        humanReadableInterpretation: String,
        wasCancelled: Bool = false,
        issues: [APFSStorageIssue] = []
    ) {
        self.dataVolumePhysicalInUseBytes = dataVolumePhysicalInUseBytes
        self.filesystemAttributedBytes = filesystemAttributedBytes
        self.internalPhysicalGapBytes = internalPhysicalGapBytes
        self.allocationDeltaSummary = allocationDeltaSummary
        self.waterfallItems = waterfallItems
        self.protectedSummary = protectedSummary
        self.additiveExplainedPortionBytes = additiveExplainedPortionBytes
        self.nonAdditiveEvidencedPortionBytes = nonAdditiveEvidencedPortionBytes
        self.unresolvedResidualGapBytes = unresolvedResidualGapBytes
        self.humanReadableInterpretation = humanReadableInterpretation
        self.wasCancelled = wasCancelled
        self.issues = issues
    }

    static let empty = DataVolumeInternalGapReport(
        dataVolumePhysicalInUseBytes: nil,
        filesystemAttributedBytes: 0,
        internalPhysicalGapBytes: nil,
        allocationDeltaSummary: .empty,
        waterfallItems: [],
        protectedSummary: .empty,
        additiveExplainedPortionBytes: 0,
        nonAdditiveEvidencedPortionBytes: 0,
        unresolvedResidualGapBytes: nil,
        humanReadableInterpretation: "Data volume internal gap analysis is currently unavailable.",
        wasCancelled: false,
        issues: []
    )
}
