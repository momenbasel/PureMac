import Foundation

// MARK: - Storage Analysis Types

/// The filesystem object represented by a storage-analysis node.
///
/// This type intentionally does not describe whether an item can be cleaned.
/// Storage analysis and cleanup are separate domains.
enum StorageItemType: String, Codable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case volumeBoundary
    case other
    case unknown
}

/// Describes how completely the scanner could inspect a filesystem object.
enum StorageAccessibility: String, Codable, Sendable {
    case accessible
    case partiallyAccessible
    case inaccessible
    case skippedDifferentVolume
    case cancelled
}

enum StorageScanIssueKind: String, Codable, Sendable {
    case permissionDenied
    case unreadable
    case metadataUnavailable
    case directoryEnumerationFailed
    case notDirectory
    case differentVolume
    case cancelled
}

/// A recoverable problem encountered while building a storage tree.
///
/// Scanner errors are data rather than thrown failures so a partial tree can
/// still explain every location that was successfully inspected.
struct StorageScanIssue: Identifiable, Hashable, Codable, Sendable {
    var id: String {
        let errorCode = posixErrorCode.map { String($0) } ?? "none"
        return "\(path)|\(kind.rawValue)|\(errorCode)|\(message)"
    }

    let path: String
    let kind: StorageScanIssueKind
    let message: String
    let posixErrorCode: Int32?
}

/// An application that has been reliably associated with analyzed storage.
///
/// Some storage locations, notably Group Containers, can be shared by more
/// than one application. This value complements the legacy single-owner
/// metadata without changing its meaning for existing analyzers.
struct StorageApplicationOwner: Hashable, Codable, Sendable {
    let bundleIdentifier: String
    let displayName: String?
}

/// An extension point for future attribution and explanation work.
///
/// The first scanner leaves these fields unset. Keeping future semantic data
/// outside the filesystem facts allows application ownership, storage
/// categories, safety classifications, and confidence to be added without
/// changing the tree shape or coupling the analyzer to `CleanableItem`.
struct StorageAnalysisMetadata: Hashable, Codable, Sendable {
    /// A bundle identifier observed from storage naming or metadata. This can
    /// exist even when no installed application owner has been verified.
    var bundleIdentifier: String?
    /// A structurally valid shared-container entitlement identifier. It is
    /// intentionally distinct from an application's bundle identifier.
    var groupContainerIdentifier: String?
    var owningApplicationIdentifier: String?
    var owningApplicationName: String?
    /// Verified owners for storage that can legitimately be shared. Optional
    /// keeps decoding compatible with metadata produced before this field was
    /// introduced while distinguishing unresolved ownership from an answer.
    var owningApplications: [StorageApplicationOwner]?
    var storageCategoryIdentifier: String?
    var safetyClassificationIdentifier: String?
    var confidence: Double?
    var isUnusuallyLarge: Bool?
    var explanation: String?
    var attributes: [String: String]

    init(
        bundleIdentifier: String? = nil,
        groupContainerIdentifier: String? = nil,
        owningApplicationIdentifier: String? = nil,
        owningApplicationName: String? = nil,
        owningApplications: [StorageApplicationOwner]? = nil,
        storageCategoryIdentifier: String? = nil,
        safetyClassificationIdentifier: String? = nil,
        confidence: Double? = nil,
        isUnusuallyLarge: Bool? = nil,
        explanation: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.groupContainerIdentifier = groupContainerIdentifier
        self.owningApplicationIdentifier = owningApplicationIdentifier
        self.owningApplicationName = owningApplicationName
        self.owningApplications = owningApplications
        self.storageCategoryIdentifier = storageCategoryIdentifier
        self.safetyClassificationIdentifier = safetyClassificationIdentifier
        self.confidence = confidence
        self.isUnusuallyLarge = isUnusuallyLarge
        self.explanation = explanation
        self.attributes = attributes
    }
}

/// A node in a hierarchical, read-only filesystem analysis.
///
/// `logicalSize` and `allocatedSize` are subtree totals: they include this
/// node's counted bytes and all counted descendants. `ownLogicalSize` and
/// `ownAllocatedSize` contain only the filesystem object's own metadata.
/// Consumers should use the root totals or sum leaf/own values, but should not
/// add a parent subtree total to its children again.
struct StorageNode: Identifiable, Hashable, Codable, Sendable {
    var id: String { absolutePath }

    let name: String
    let absolutePath: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let ownLogicalSize: Int64
    let ownAllocatedSize: Int64
    let itemType: StorageItemType
    let children: [StorageNode]
    let accessibility: StorageAccessibility
    let scanIssues: [StorageScanIssue]
    let isHidden: Bool
    let isSymbolicLink: Bool

    /// False when this object remains visible in the tree but its own bytes
    /// have already been attributed elsewhere (for example, a hard link).
    let isCountedInParentTotals: Bool

    let metadata: StorageAnalysisMetadata
}

/// The complete output of one filesystem analysis operation.
struct StorageAnalysisResult: Hashable, Codable, Sendable {
    let root: StorageNode
    let startedAt: Date
    let completedAt: Date
    let rootDeviceIdentifier: UInt64?
    let wasCancelled: Bool

    /// A flat summary of all issues also attached to their corresponding
    /// nodes, useful to callers that do not need to walk the tree first.
    let issues: [StorageScanIssue]
}
