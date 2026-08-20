import Foundation

enum APFSAnalysisState: String, Codable, Sendable {
    case complete
    case partial
    case nonAPFS
    case unavailable
    case cancelled
}

enum APFSFilesystemKind: String, Codable, Sendable {
    case apfs
    case nonAPFS
    case unknown
}

enum APFSDataVolumeRelationship: String, Codable, Sendable {
    case dataVolume
    case systemVolume
    case volumeGroupMember
    case notApplicable
    case unknown
}

enum APFSPurgeableEstimateKnowledge: String, Codable, Sendable {
    case estimated
    case unavailable
}

struct APFSVolumeCapacity: Hashable, Codable, Sendable {
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let usedCapacity: Int64?
    let availableCapacityForImportantUsage: Int64?
    let availableCapacityForOpportunisticUsage: Int64?
    let purgeableEstimate: Int64?
    let purgeableEstimateKnowledge: APFSPurgeableEstimateKnowledge
}

struct APFSVolumeInformation: Hashable, Codable, Sendable {
    let name: String?
    let volumeIdentifier: String?
    let volumeUUID: String?
    let containerIdentifier: String?
    let volumeGroupIdentifier: String?
    let filesystemType: String?
    let filesystemKind: APFSFilesystemKind
    let mountPoint: String
    let dataVolumeRelationship: APFSDataVolumeRelationship
    let capacity: APFSVolumeCapacity
}

enum APFSSnapshotType: String, Codable, Sendable {
    case timeMachine
    case operatingSystemUpdate
    case otherAPFS
    case unknown
}

enum APFSSnapshotSource: String, Codable, Sendable {
    case tmutil
    case diskutil
    case tmutilAndDiskutil
}

enum APFSSnapshotSizeKnowledge: String, Codable, Sendable {
    case reportedBySystem
    case unavailable
}

/// APFS copy-on-write data can share extents with the live filesystem. Even a
/// system-reported snapshot size is therefore never automatically additive.
enum APFSSnapshotStorageRelationship: String, Codable, Sendable {
    case sharedNonAdditive
    case sizeUnavailable
    case unknown
}

struct APFSSnapshotInformation: Identifiable, Hashable, Codable, Sendable {
    let identifier: String
    let name: String?
    let uuid: String?
    let creationDate: Date?
    let size: Int64?
    let sizeKnowledge: APFSSnapshotSizeKnowledge
    let type: APFSSnapshotType
    let source: APFSSnapshotSource
    let storageRelationship: APFSSnapshotStorageRelationship

    var id: String { identifier }
}

enum APFSAccountingRelationship: String, Codable, Sendable {
    case volumeMetadataAndSnapshotsAreNonAdditiveToFilesystemTrees
}

enum APFSStorageIssueKind: String, Codable, Sendable {
    case volumeStatisticsUnavailable
    case commandUnavailable
    case commandFailed
    case permissionDenied
    case malformedPlist
    case malformedOutput
    case partialMetadata
    case cancelled
}

struct APFSStorageIssue: Identifiable, Hashable, Codable, Sendable {
    let kind: APFSStorageIssueKind
    let message: String
    let source: String?

    var id: String { "\(kind.rawValue)|\(source ?? "")|\(message)" }
}

struct APFSStorageReport: Hashable, Codable, Sendable {
    let volume: APFSVolumeInformation
    let snapshots: [APFSSnapshotInformation]
    let state: APFSAnalysisState
    let accountingRelationship: APFSAccountingRelationship
    let wasCancelled: Bool
    let issues: [APFSStorageIssue]
}

struct APFSCommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

struct APFSCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let launchError: String?
    let wasCancelled: Bool
}
