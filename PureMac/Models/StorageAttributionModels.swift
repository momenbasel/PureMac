import Foundation

/// Typed classification of a top-level directory or entry on the writable Data volume.
enum DataVolumeRegionClassification: String, Codable, Sendable {
    case ownedByExistingAnalyzer
    case measuredByCoverageExpansion
    case partiallyMeasured
    case protectedUnreadable
    case separateVolumeOrMount
    case nonAdditiveAPFS
    case intentionallyExcluded
    case unknown

    var displayName: String {
        switch self {
        case .ownedByExistingAnalyzer: return "Owned by Analyzer"
        case .measuredByCoverageExpansion: return "Measured in Expansion"
        case .partiallyMeasured: return "Partially Measured"
        case .protectedUnreadable: return "Protected by macOS"
        case .separateVolumeOrMount: return "Separate Mount"
        case .nonAdditiveAPFS: return "Non-Additive APFS"
        case .intentionallyExcluded: return "Intentionally Excluded"
        case .unknown: return "Unknown"
        }
    }
}

/// A root-level region on `/System/Volumes/Data` with ownership and measurement status.
struct DataVolumeRootAttribution: Identifiable, Hashable, Codable, Sendable {
    let originalPath: String
    let normalizedPath: String
    let name: String
    let classification: DataVolumeRegionClassification
    let canonicalOwner: StorageCanonicalRoot?
    let analyzerStage: StorageAnalyzerStage?
    let allocatedBytes: Int64?
    let logicalBytes: Int64?
    let isFilesystemAdditive: Bool
    let statusExplanation: String
    let isProtectedSystem: Bool

    var id: String { normalizedPath }

    init(
        originalPath: String,
        normalizedPath: String,
        name: String,
        classification: DataVolumeRegionClassification,
        canonicalOwner: StorageCanonicalRoot?,
        analyzerStage: StorageAnalyzerStage?,
        allocatedBytes: Int64?,
        logicalBytes: Int64?,
        isFilesystemAdditive: Bool,
        statusExplanation: String,
        isProtectedSystem: Bool
    ) {
        self.originalPath = originalPath
        self.normalizedPath = normalizedPath
        self.name = name
        self.classification = classification
        self.canonicalOwner = canonicalOwner
        self.analyzerStage = analyzerStage
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.isFilesystemAdditive = isFilesystemAdditive
        self.statusExplanation = statusExplanation
        self.isProtectedSystem = isProtectedSystem
    }
}

/// Confidence / measurement status for an attribution item.
enum StorageAttributionStatus: String, Codable, CaseIterable, Sendable {
    case measured
    case partial
    case protectedUnreadable
    case estimate
    case nonAdditive
    case unknown

    var displayName: String {
        switch self {
        case .measured: return "Measured"
        case .partial: return "Partial"
        case .protectedUnreadable: return "Protected"
        case .estimate: return "Estimate"
        case .nonAdditive: return "Non-additive"
        case .unknown: return "Unknown"
        }
    }
}

/// High-level attribution groups explaining the composition of volume storage.
enum StorageAttributionCategory: String, Codable, CaseIterable, Sendable {
    case measuredGaps
    case protectedSystemStorage
    case systemManagedStorage
    case apfsAndNonAdditive
    case stillUnattributed

    var displayName: String {
        switch self {
        case .measuredGaps: return "Measured Gaps"
        case .protectedSystemStorage: return "Protected System Storage"
        case .systemManagedStorage: return "System-Managed Storage"
        case .apfsAndNonAdditive: return "APFS & Non-Additive Factors"
        case .stillUnattributed: return "Still Unattributed"
        }
    }

    var explanation: String {
        switch self {
        case .measuredGaps:
            return "Filesystem regions discovered and measured by PureMac outside specialized roots."
        case .protectedSystemStorage:
            return "Locations governed by macOS System Integrity Protection and privacy access controls."
        case .systemManagedStorage:
            return "System services, virtual memory, sleep image, update assets, and system indexing databases."
        case .apfsAndNonAdditive:
            return "APFS volume-level features such as snapshots, purgeable capacity, shared extents, and metadata."
        case .stillUnattributed:
            return "Remaining unexplained volume capacity not yet attributed by measured or evidenced factors."
        }
    }
}

/// An individual attribution evidence row.
struct StorageAttributionItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let category: StorageAttributionCategory
    let name: String
    let path: String?
    let status: StorageAttributionStatus
    let allocatedBytes: Int64?
    let explanation: String
    let isFilesystemAdditive: Bool

    init(
        id: String,
        category: StorageAttributionCategory,
        name: String,
        path: String? = nil,
        status: StorageAttributionStatus,
        allocatedBytes: Int64?,
        explanation: String,
        isFilesystemAdditive: Bool
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.path = path
        self.status = status
        self.allocatedBytes = allocatedBytes
        self.explanation = explanation
        self.isFilesystemAdditive = isFilesystemAdditive
    }
}

/// Comprehensive report explaining the volume's storage state and the unexplained gap.
struct StorageUnexplainedAttributionReport: Hashable, Codable, Sendable {
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

    let wasCancelled: Bool
    let issues: [StorageScanIssue]

    static let empty = StorageUnexplainedAttributionReport(
        volumeUsedBytes: nil,
        explainedAllocatedBytes: 0,
        unexplainedBytes: nil,
        residualUnattributedBytes: nil,
        dataVolumeRoots: [],
        attributionItems: [],
        vmFootprintBytes: nil,
        sleepImageBytes: nil,
        snapshotFootprintBytes: nil,
        purgeableEstimateBytes: nil,
        wasCancelled: false,
        issues: []
    )

    init(
        volumeUsedBytes: Int64?,
        explainedAllocatedBytes: Int64,
        unexplainedBytes: Int64?,
        residualUnattributedBytes: Int64?,
        dataVolumeRoots: [DataVolumeRootAttribution],
        attributionItems: [StorageAttributionItem],
        vmFootprintBytes: Int64?,
        sleepImageBytes: Int64?,
        snapshotFootprintBytes: Int64?,
        purgeableEstimateBytes: Int64?,
        wasCancelled: Bool,
        issues: [StorageScanIssue]
    ) {
        self.volumeUsedBytes = volumeUsedBytes
        self.explainedAllocatedBytes = explainedAllocatedBytes
        self.unexplainedBytes = unexplainedBytes
        self.residualUnattributedBytes = residualUnattributedBytes
        self.dataVolumeRoots = dataVolumeRoots
        self.attributionItems = attributionItems
        self.vmFootprintBytes = vmFootprintBytes
        self.sleepImageBytes = sleepImageBytes
        self.snapshotFootprintBytes = snapshotFootprintBytes
        self.purgeableEstimateBytes = purgeableEstimateBytes
        self.wasCancelled = wasCancelled
        self.issues = issues
    }
}
