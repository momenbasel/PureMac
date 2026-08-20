import Foundation

/// Evidence of an individual APFS volume residing in the same APFS container pool.
struct APFSSiblingVolumeEvidence: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let role: String
    let deviceIdentifier: String
    let capacityInUseBytes: Int64?

    init(
        name: String,
        role: String,
        deviceIdentifier: String,
        capacityInUseBytes: Int64?
    ) {
        self.id = deviceIdentifier
        self.name = name
        self.role = role
        self.deviceIdentifier = deviceIdentifier
        self.capacityInUseBytes = capacityInUseBytes
    }
}

/// Container-level APFS evidence detailing shared storage pool metrics and sibling volumes.
struct APFSContainerEvidence: Hashable, Codable, Sendable {
    let containerReference: String
    let containerUUID: String?
    let totalCapacityBytes: Int64?
    let freeCapacityBytes: Int64?
    let physicalStoreIdentifier: String?
    let volumes: [APFSSiblingVolumeEvidence]
    let totalSiblingVolumeBytesOutsideData: Int64

    init(
        containerReference: String,
        containerUUID: String?,
        totalCapacityBytes: Int64?,
        freeCapacityBytes: Int64?,
        physicalStoreIdentifier: String?,
        volumes: [APFSSiblingVolumeEvidence],
        totalSiblingVolumeBytesOutsideData: Int64
    ) {
        self.containerReference = containerReference
        self.containerUUID = containerUUID
        self.totalCapacityBytes = totalCapacityBytes
        self.freeCapacityBytes = freeCapacityBytes
        self.physicalStoreIdentifier = physicalStoreIdentifier
        self.volumes = volumes
        self.totalSiblingVolumeBytesOutsideData = totalSiblingVolumeBytesOutsideData
    }
}

/// Specific physical evidence for the target writable Data volume.
struct APFSVolumeEvidence: Hashable, Codable, Sendable {
    let name: String
    let mountPoint: String
    let deviceIdentifier: String
    let volumeUUID: String?
    let volumeGroupUUID: String?
    let roles: [String]
    let capacityInUseBytes: Int64?
    let isEncrypted: Bool
    let isSealed: Bool
    let isWritable: Bool

    init(
        name: String,
        mountPoint: String,
        deviceIdentifier: String,
        volumeUUID: String?,
        volumeGroupUUID: String?,
        roles: [String],
        capacityInUseBytes: Int64?,
        isEncrypted: Bool,
        isSealed: Bool,
        isWritable: Bool
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.deviceIdentifier = deviceIdentifier
        self.volumeUUID = volumeUUID
        self.volumeGroupUUID = volumeGroupUUID
        self.roles = roles
        self.capacityInUseBytes = capacityInUseBytes
        self.isEncrypted = isEncrypted
        self.isSealed = isSealed
        self.isWritable = isWritable
    }
}

/// APFS snapshot evidence summary.
struct APFSSnapshotEvidence: Hashable, Codable, Sendable {
    let snapshotCount: Int
    let totalReportedSnapshotBytes: Int64?
    let snapshots: [APFSSnapshotInformation]
    let isNonAdditive: Bool
    let explanation: String

    init(
        snapshotCount: Int,
        totalReportedSnapshotBytes: Int64?,
        snapshots: [APFSSnapshotInformation],
        isNonAdditive: Bool = true,
        explanation: String = "APFS copy-on-write snapshots share extents with the live filesystem and are non-additive."
    ) {
        self.snapshotCount = snapshotCount
        self.totalReportedSnapshotBytes = totalReportedSnapshotBytes
        self.snapshots = snapshots
        self.isNonAdditive = isNonAdditive
        self.explanation = explanation
    }

    static let empty = APFSSnapshotEvidence(
        snapshotCount: 0,
        totalReportedSnapshotBytes: nil,
        snapshots: []
    )
}

/// System-managed storage evidence (VM swap, sleepimage, VM volume, system databases).
struct APFSSystemManagedEvidence: Hashable, Codable, Sendable {
    let vmFootprintBytes: Int64?
    let swapFileBytes: Int64?
    let sleepImageBytes: Int64?
    let vmVolumeBytes: Int64?
    let hasSystemIndexingDatabases: Bool
    let explanation: String

    init(
        vmFootprintBytes: Int64?,
        swapFileBytes: Int64?,
        sleepImageBytes: Int64?,
        vmVolumeBytes: Int64?,
        hasSystemIndexingDatabases: Bool,
        explanation: String
    ) {
        self.vmFootprintBytes = vmFootprintBytes
        self.swapFileBytes = swapFileBytes
        self.sleepImageBytes = sleepImageBytes
        self.vmVolumeBytes = vmVolumeBytes
        self.hasSystemIndexingDatabases = hasSystemIndexingDatabases
        self.explanation = explanation
    }

    static let empty = APFSSystemManagedEvidence(
        vmFootprintBytes: nil,
        swapFileBytes: nil,
        sleepImageBytes: nil,
        vmVolumeBytes: nil,
        hasSystemIndexingDatabases: false,
        explanation: "No system-managed virtual memory or update storage detected."
    )
}

/// Protected system storage evidence.
struct APFSProtectedStorageEvidence: Hashable, Codable, Sendable {
    let protectedRegionCount: Int
    let inaccessibleKnownLowerBoundBytes: Int64
    let unreadablePathCount: Int
    let explanation: String

    init(
        protectedRegionCount: Int,
        inaccessibleKnownLowerBoundBytes: Int64,
        unreadablePathCount: Int,
        explanation: String
    ) {
        self.protectedRegionCount = protectedRegionCount
        self.inaccessibleKnownLowerBoundBytes = inaccessibleKnownLowerBoundBytes
        self.unreadablePathCount = unreadablePathCount
        self.explanation = explanation
    }

    static let empty = APFSProtectedStorageEvidence(
        protectedRegionCount: 0,
        inaccessibleKnownLowerBoundBytes: 0,
        unreadablePathCount: 0,
        explanation: "No macOS protected system access barriers recorded."
    )
}

/// Quantitative metrics bridging physical APFS volume used bytes to filesystem attributed bytes.
struct APFSPhysicalAccountingMetrics: Hashable, Codable, Sendable {
    /// Physical container used capacity (e.g. 217.20 GB from container total - free).
    let physicalVolumeUsedBytes: Int64?
    /// Exclusive physical allocation reported for the Data volume (e.g. 189.65 GB).
    let dataVolumePhysicalInUseBytes: Int64?
    /// Unique allocated filesystem bytes attributed by PureMac scanners (e.g. 143.24 GB).
    let filesystemAttributedBytes: Int64
    /// Total physical space consumed by sibling APFS volumes in the container (e.g. 27.41 GB).
    let containerSiblingVolumesBytes: Int64
    /// Overall physical accounting gap: `max(physicalVolumeUsedBytes - filesystemAttributedBytes, 0)`.
    let physicalAccountingGapBytes: Int64?
    /// Data volume internal delta: `max(dataVolumePhysicalInUseBytes - filesystemAttributedBytes, 0)`.
    let dataVolumeInternalGapBytes: Int64?
    /// Purgeable capacity estimate (kept non-additive).
    let purgeableEstimateBytes: Int64?
    /// Difference between container used and sum of sibling volumes + data volume in-use.
    let containerAccountingDiscrepancyBytes: Int64?

    init(
        physicalVolumeUsedBytes: Int64?,
        dataVolumePhysicalInUseBytes: Int64?,
        filesystemAttributedBytes: Int64,
        containerSiblingVolumesBytes: Int64,
        physicalAccountingGapBytes: Int64?,
        dataVolumeInternalGapBytes: Int64?,
        purgeableEstimateBytes: Int64?,
        containerAccountingDiscrepancyBytes: Int64?
    ) {
        self.physicalVolumeUsedBytes = physicalVolumeUsedBytes
        self.dataVolumePhysicalInUseBytes = dataVolumePhysicalInUseBytes
        self.filesystemAttributedBytes = filesystemAttributedBytes
        self.containerSiblingVolumesBytes = containerSiblingVolumesBytes
        self.physicalAccountingGapBytes = physicalAccountingGapBytes
        self.dataVolumeInternalGapBytes = dataVolumeInternalGapBytes
        self.purgeableEstimateBytes = purgeableEstimateBytes
        self.containerAccountingDiscrepancyBytes = containerAccountingDiscrepancyBytes
    }
}

/// High-level deterministic classification for physical reconciliation.
enum APFSPhysicalReconciliationStatus: String, Codable, CaseIterable, Sendable {
    case fullyReconciled
    case mostlyReconciled
    case filesystemCoverageLimited
    case apfsNonAdditiveFactorsPresent
    case protectedSystemStoragePresent
    case physicalAccountingGapRemaining
    case insufficientEvidence

    var displayName: String {
        switch self {
        case .fullyReconciled: return "Fully Reconciled"
        case .mostlyReconciled: return "Mostly Reconciled"
        case .filesystemCoverageLimited: return "Coverage Limited"
        case .apfsNonAdditiveFactorsPresent: return "APFS Non-Additive Factors Present"
        case .protectedSystemStoragePresent: return "Protected System Storage Present"
        case .physicalAccountingGapRemaining: return "Physical Accounting Gap Remaining"
        case .insufficientEvidence: return "Insufficient Evidence"
        }
    }
}

/// Comprehensive physical reconciliation report explaining the physical-accounting gap.
struct APFSPhysicalReconciliationReport: Hashable, Codable, Sendable {
    let status: APFSPhysicalReconciliationStatus
    let metrics: APFSPhysicalAccountingMetrics
    let targetVolume: APFSVolumeEvidence?
    let container: APFSContainerEvidence?
    let snapshots: APFSSnapshotEvidence
    let systemManaged: APFSSystemManagedEvidence
    let protectedStorage: APFSProtectedStorageEvidence
    let dataVolumeInternalGap: DataVolumeInternalGapReport?
    let humanReadableInterpretation: String
    let warnings: [String]
    let evidenceSources: [String]
    let wasCancelled: Bool
    let issues: [APFSStorageIssue]

    init(
        status: APFSPhysicalReconciliationStatus,
        metrics: APFSPhysicalAccountingMetrics,
        targetVolume: APFSVolumeEvidence?,
        container: APFSContainerEvidence?,
        snapshots: APFSSnapshotEvidence,
        systemManaged: APFSSystemManagedEvidence,
        protectedStorage: APFSProtectedStorageEvidence,
        dataVolumeInternalGap: DataVolumeInternalGapReport? = nil,
        humanReadableInterpretation: String,
        warnings: [String] = [],
        evidenceSources: [String] = [],
        wasCancelled: Bool = false,
        issues: [APFSStorageIssue] = []
    ) {
        self.status = status
        self.metrics = metrics
        self.targetVolume = targetVolume
        self.container = container
        self.snapshots = snapshots
        self.systemManaged = systemManaged
        self.protectedStorage = protectedStorage
        self.dataVolumeInternalGap = dataVolumeInternalGap
        self.humanReadableInterpretation = humanReadableInterpretation
        self.warnings = warnings
        self.evidenceSources = evidenceSources
        self.wasCancelled = wasCancelled
        self.issues = issues
    }

    static let empty = APFSPhysicalReconciliationReport(
        status: .insufficientEvidence,
        metrics: APFSPhysicalAccountingMetrics(
            physicalVolumeUsedBytes: nil,
            dataVolumePhysicalInUseBytes: nil,
            filesystemAttributedBytes: 0,
            containerSiblingVolumesBytes: 0,
            physicalAccountingGapBytes: nil,
            dataVolumeInternalGapBytes: nil,
            purgeableEstimateBytes: nil,
            containerAccountingDiscrepancyBytes: nil
        ),
        targetVolume: nil,
        container: nil,
        snapshots: .empty,
        systemManaged: .empty,
        protectedStorage: .empty,
        dataVolumeInternalGap: nil,
        humanReadableInterpretation: "Insufficient physical volume information available for reconciliation.",
        warnings: [],
        evidenceSources: [],
        wasCancelled: false,
        issues: []
    )
}
