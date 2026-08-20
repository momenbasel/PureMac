import Darwin
import Foundation

/// Informational categories for hidden entries located directly on the
/// writable macOS Data volume. These values describe attribution only.
enum DataVolumeHiddenStorageCategory: String, Codable, CaseIterable, Sendable {
    case adobeTemporaryStorage = "data-volume-hidden.adobe-temporary-storage"
    case filesystemEvents = "data-volume-hidden.filesystem-events"
    case spotlightIndex = "data-volume-hidden.spotlight-index"
    case documentRevisions = "data-volume-hidden.document-revisions"
    case temporaryItems = "data-volume-hidden.temporary-items"
    case trashes = "data-volume-hidden.trashes"
    case unknown = "data-volume-hidden.unknown"

    var explanation: String {
        switch self {
        case .adobeTemporaryStorage:
            return "Hidden temporary storage attributed by name to Adobe products; no cleanup behavior is implied."
        case .filesystemEvents:
            return "Filesystem event history maintained by macOS; this label does not imply cleanability."
        case .spotlightIndex:
            return "Spotlight search indexing data managed by macOS; this label does not imply cleanability."
        case .documentRevisions:
            return "Document revision and version storage managed by macOS; this label does not imply cleanability."
        case .temporaryItems:
            return "Hidden temporary-item storage managed by macOS and applications; no cleanup behavior is implied."
        case .trashes:
            return "Hidden per-volume Trash storage; this analyzer only attributes its size."
        case .unknown:
            return "Unclassified hidden storage located directly on the writable Data volume."
        }
    }
}

/// Informational management context, deliberately separate from cleanup
/// safety or deletion eligibility.
enum DataVolumeHiddenManagementKind: String, Codable, Sendable {
    case systemManaged
    case productAttributed
    case systemAndApplicationManaged
    case unknown
}

/// Completeness of the reported numeric subtree total. An incomplete total is
/// a known lower bound and never an estimate of unreadable descendants.
enum DataVolumeHiddenSizeKnowledge: String, Codable, Sendable {
    case complete
    case incompleteDueToInaccessibility
    case incompleteDueToCancellation
    case excludedDifferentVolume
}

/// Read-only attribution of hidden entries located immediately below
/// `/System/Volumes/Data`.
///
/// The root is enumerated once. `FileTreeScanner` recursively traverses only
/// selected hidden children while preserving a shared inode-accounting context
/// across those children.
struct DataVolumeHiddenStorageAnalyzer: Sendable {
    enum MetadataKey {
        static let directChildCount = "dataVolumeHidden.directChildCount"
        static let largeAllocatedSizeThreshold = "dataVolumeHidden.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "dataVolumeHidden.virtualDiskImageCount"
        static let virtualDiskFormat = "dataVolumeHidden.virtualDiskFormat"
        static let virtualDiskSparseState = "dataVolumeHidden.virtualDiskSparseState"
        static let managementKind = "dataVolumeHidden.managementKind"
        static let sizeKnowledge = "dataVolumeHidden.sizeKnowledge"
        static let scanScope = "dataVolumeHidden.scanScope"
        static let canonicalDataVolumePath = "dataVolumeHidden.canonicalDataVolumePath"
    }

    static let storageCategoryIdentifier = "data-volume-hidden-storage"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824
    static let defaultDataVolumeURL = URL(
        fileURLWithPath: "/System/Volumes/Data",
        isDirectory: true
    )

    private enum VirtualDiskFormat: String {
        case raw
        case img
        case qcow2
        case vmdk
        case sparseBundle = "sparsebundle"
    }

    private enum SparseState: String {
        case sparse
        case notSparse = "not-sparse"
        case unknown
    }

    private let dataVolumeURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64

    init(
        dataVolumeURL: URL = DataVolumeHiddenStorageAnalyzer.defaultDataVolumeURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = DataVolumeHiddenStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.dataVolumeURL = dataVolumeURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> StorageAnalysisResult {
        let scannedResult = await scanner.scanSelectedImmediateChildren(
            root: dataVolumeURL,
            including: { $0.isHidden }
        )
        let threshold = largeAllocatedSizeThreshold

        return await Task.detached(priority: .utility) {
            Self.enrich(
                scannedResult,
                largeAllocatedSizeThreshold: threshold
            )
        }.value
    }
}

// Internal so volume-boundary behavior can be verified without creating a
// privileged test mount.
extension DataVolumeHiddenStorageAnalyzer {
    static func enrich(
        _ result: StorageAnalysisResult,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageAnalysisResult {
        var root = result.root
        var issues = result.issues

        if root.itemType != .directory, root.itemType != .unknown {
            let issue = StorageScanIssue(
                path: root.absolutePath,
                kind: .notDirectory,
                message: "Data-volume hidden storage analysis requires a directory root.",
                posixErrorCode: ENOTDIR
            )
            var rootIssues = root.scanIssues
            if !rootIssues.contains(issue) { rootIssues.append(issue) }
            if !issues.contains(issue) { issues.append(issue) }
            root = copy(
                root,
                children: root.children,
                accessibility: .inaccessible,
                scanIssues: rootIssues,
                metadata: root.metadata
            )
        }

        root = enrichTreeMetadata(in: root)
        let entries = root.children
            .map {
                enrichImmediateHiddenEntry(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootMetadata = root.metadata
        rootMetadata.storageCategoryIdentifier = storageCategoryIdentifier
        rootMetadata.explanation = "Hidden top-level storage on the writable macOS Data volume."
        rootMetadata.attributes[MetadataKey.directChildCount] = String(entries.count)
        rootMetadata.attributes[MetadataKey.scanScope] = "selected-hidden-immediate-children-only"
        rootMetadata.attributes[MetadataKey.canonicalDataVolumePath] = root.absolutePath

        root = copy(root, children: entries, metadata: rootMetadata)
        return StorageAnalysisResult(
            root: root,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            rootDeviceIdentifier: result.rootDeviceIdentifier,
            wasCancelled: result.wasCancelled,
            issues: issues.sorted(by: issueSort)
        )
    }
}

// MARK: - Metadata Enrichment

private extension DataVolumeHiddenStorageAnalyzer {
    static func enrichImmediateHiddenEntry(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let category = category(for: node.name)
        var metadata = node.metadata
        metadata.storageCategoryIdentifier = category.rawValue
        metadata.isUnusuallyLarge = node.allocatedSize >= largeAllocatedSizeThreshold
        metadata.explanation = category.explanation
        metadata.attributes[MetadataKey.directChildCount] = String(node.children.count)
        metadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        metadata.attributes[MetadataKey.virtualDiskImageCount] = String(countVirtualDiskImages(in: node))
        metadata.attributes[MetadataKey.managementKind] = managementKind(for: category).rawValue
        return copy(node, children: node.children, metadata: metadata)
    }

    static func enrichTreeMetadata(in node: StorageNode) -> StorageNode {
        let children = node.children.map(enrichTreeMetadata)
        var metadata = node.metadata
        metadata.attributes[MetadataKey.sizeKnowledge] = sizeKnowledge(for: node.accessibility).rawValue

        if let format = virtualDiskFormat(for: node) {
            metadata.attributes[MetadataKey.virtualDiskFormat] = format.rawValue
            metadata.attributes[MetadataKey.virtualDiskSparseState] = sparseState(for: node).rawValue
        }

        return copy(node, children: children, metadata: metadata)
    }

    static func category(for name: String) -> DataVolumeHiddenStorageCategory {
        switch name {
        case ".adobeTemp": return .adobeTemporaryStorage
        case ".fseventsd": return .filesystemEvents
        case ".Spotlight-V100": return .spotlightIndex
        case ".DocumentRevisions-V100": return .documentRevisions
        case ".TemporaryItems": return .temporaryItems
        case ".Trashes": return .trashes
        default: return .unknown
        }
    }

    static func managementKind(
        for category: DataVolumeHiddenStorageCategory
    ) -> DataVolumeHiddenManagementKind {
        switch category {
        case .adobeTemporaryStorage:
            return .productAttributed
        case .filesystemEvents, .spotlightIndex, .documentRevisions:
            return .systemManaged
        case .temporaryItems, .trashes:
            return .systemAndApplicationManaged
        case .unknown:
            return .unknown
        }
    }

    static func sizeKnowledge(
        for accessibility: StorageAccessibility
    ) -> DataVolumeHiddenSizeKnowledge {
        switch accessibility {
        case .accessible: return .complete
        case .partiallyAccessible, .inaccessible: return .incompleteDueToInaccessibility
        case .cancelled: return .incompleteDueToCancellation
        case .skippedDifferentVolume: return .excludedDifferentVolume
        }
    }

    private static func virtualDiskFormat(for node: StorageNode) -> VirtualDiskFormat? {
        guard !node.isSymbolicLink,
              node.itemType == .regularFile || node.itemType == .directory else {
            return nil
        }

        switch URL(fileURLWithPath: node.absolutePath).pathExtension.lowercased() {
        case "raw": return .raw
        case "img": return .img
        case "qcow2": return .qcow2
        case "vmdk": return .vmdk
        case "sparsebundle": return .sparseBundle
        default: return nil
        }
    }

    private static func sparseState(for node: StorageNode) -> SparseState {
        guard node.itemType == .regularFile else { return .unknown }
        return node.ownLogicalSize > node.ownAllocatedSize ? .sparse : .notSparse
    }

    static func countVirtualDiskImages(in root: StorageNode) -> Int {
        var count = 0
        var pending = [root]
        while let node = pending.popLast() {
            if virtualDiskFormat(for: node) != nil { count += 1 }
            pending.append(contentsOf: node.children)
        }
        return count
    }

    static func allocatedSizeDescending(_ left: StorageNode, _ right: StorageNode) -> Bool {
        if left.allocatedSize != right.allocatedSize {
            return left.allocatedSize > right.allocatedSize
        }
        if left.logicalSize != right.logicalSize {
            return left.logicalSize > right.logicalSize
        }
        return left.absolutePath < right.absolutePath
    }

    static func copy(
        _ node: StorageNode,
        children: [StorageNode],
        accessibility: StorageAccessibility? = nil,
        scanIssues: [StorageScanIssue]? = nil,
        metadata: StorageAnalysisMetadata
    ) -> StorageNode {
        StorageNode(
            name: node.name,
            absolutePath: node.absolutePath,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            ownLogicalSize: node.ownLogicalSize,
            ownAllocatedSize: node.ownAllocatedSize,
            itemType: node.itemType,
            children: children,
            accessibility: accessibility ?? node.accessibility,
            scanIssues: scanIssues ?? node.scanIssues,
            isHidden: node.isHidden,
            isSymbolicLink: node.isSymbolicLink,
            isCountedInParentTotals: node.isCountedInParentTotals,
            metadata: metadata
        )
    }

    static func issueSort(_ left: StorageScanIssue, _ right: StorageScanIssue) -> Bool {
        if left.path != right.path { return left.path < right.path }
        if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
        return left.message < right.message
    }
}
