import Foundation

/// Classification of immediate children under `/System/Volumes/Data`.
///
/// This provides a non-invasive safety net preventing future blind spots
/// where newly added macOS directories are omitted from both canonical
/// analyzers and coverage expansion.
enum DataVolumeTopLevelOwnershipStatus: String, Codable, Sendable {
    /// Owned directly by a dedicated canonical analyzer (e.g. /Applications, /Users, /private).
    case ownedByCanonicalAnalyzer
    /// Owned and measured by the coverage expansion pass (e.g. /System/Volumes/Data/macOS Install Data).
    case ownedByCoverageExpansion
    /// Firmlink alias that normalizes to a standard root (e.g. /System/Volumes/Data/var -> /private/var).
    case firmlinkAlias
    /// Intentionally non-additive (e.g. /System/Volumes/Data/Volumes, snapshots, firmlinked System mount).
    case intentionallyNonAdditive
    /// An unowned entry that contains allocated blocks on the Data volume.
    case unownedPotentialCoverageGap
}

/// Diagnostic report entry for one immediate child of `/System/Volumes/Data`.
struct DataVolumeTopLevelSafetyNetEntry: Identifiable, Hashable, Codable, Sendable {
    let originalPath: String
    let normalizedPath: String
    let name: String
    let ownershipStatus: DataVolumeTopLevelOwnershipStatus
    let owningAnalyzerStage: StorageAnalyzerStage?
    let canonicalOwner: StorageCanonicalRoot?
    let allocatedBytes: Int64?
    let isFilesystemAdditive: Bool
    let reason: String

    var id: String { originalPath }
}

/// Comprehensive safety-net report auditing immediate children of `/System/Volumes/Data`.
struct DataVolumeTopLevelSafetyNetReport: Hashable, Codable, Sendable {
    let checkedDirectoryPath: String
    let entries: [DataVolumeTopLevelSafetyNetEntry]
    let totalEntriesCount: Int
    let unownedEntriesCount: Int
    let isFullyCovered: Bool

    static let empty = DataVolumeTopLevelSafetyNetReport(
        checkedDirectoryPath: "/System/Volumes/Data",
        entries: [],
        totalEntriesCount: 0,
        unownedEntriesCount: 0,
        isFullyCovered: true
    )
}
