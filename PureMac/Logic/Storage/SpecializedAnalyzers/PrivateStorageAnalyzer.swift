import Darwin
import Foundation

/// Explanatory categories for `/private` and the immediate children of
/// `/private/var`. These labels describe storage purpose only and have no
/// cleanup or deletion meaning.
enum PrivateStorageCategory: String, Codable, CaseIterable, Sendable {
    case variableState = "private.var"
    case temporary = "private.tmp"
    case configuration = "private.etc"
    case otherTopLevel = "private.other"
    case varFolders = "private.var.folders"
    case varVirtualMemory = "private.var.vm"
    case varDatabases = "private.var.db"
    case varLogs = "private.var.log"
    case varTemporary = "private.var.tmp"
    case varRuntime = "private.var.run"
    case varRoot = "private.var.root"
    case varProtected = "private.var.protected"
    case varAudit = "private.var.audit"
    case otherVarChild = "private.var.other"

    var explanation: String {
        switch self {
        case .variableState:
            return "Persistent and temporary state managed by macOS, services, and applications."
        case .temporary:
            return "System-wide temporary storage; this label does not imply that its contents are currently disposable."
        case .configuration:
            return "System-wide configuration and service settings."
        case .otherTopLevel:
            return "Other storage directly inside /private."
        case .varFolders:
            return "Per-user and per-process caches, temporary files, application state, and other macOS-managed data."
        case .varVirtualMemory:
            return "Protected system-managed virtual-memory and swap-related storage."
        case .varDatabases:
            return "Protected databases and state maintained by macOS and system-wide services."
        case .varLogs:
            return "System and service logs represented for storage attribution only."
        case .varTemporary:
            return "Temporary files used by system services and applications; no cleanup behavior is implied."
        case .varRuntime:
            return "Runtime state used by system services and background processes."
        case .varRoot:
            return "Protected state belonging to the system administrator account."
        case .varProtected:
            return "Protected system and application state governed by macOS access controls."
        case .varAudit:
            return "Protected security and audit records maintained by macOS."
        case .otherVarChild:
            return "Other system or application state directly inside /private/var."
        }
    }
}

/// Informational handling context for a private-storage node. This is
/// deliberately separate from cleanup safety classifications.
enum PrivateStorageManagementKind: String, Codable, Sendable {
    case systemManaged
    case protectedSystemState
    case temporaryStorage
    case applicationAndSystemState
    case systemConfiguration
    case unclassified
}

/// Whether a numeric subtree total is complete. Incomplete totals are known
/// lower bounds: unreadable descendants are never estimated or represented as
/// known zero-byte storage.
enum PrivateStorageSizeKnowledge: String, Codable, Sendable {
    case complete
    case incompleteDueToInaccessibility
    case incompleteDueToCancellation
    case excludedDifferentVolume
}

/// Read-only analysis of the canonical `/private` filesystem tree.
///
/// `FileTreeScanner` owns traversal, physical/logical accounting, hard-link
/// deduplication, symlink handling, volume boundaries, and scan issues. This
/// analyzer only enriches the resulting nodes for future storage explanation.
struct PrivateStorageAnalyzer: Sendable {
    enum MetadataKey {
        static let directChildCount = "privateStorage.directChildCount"
        static let largeAllocatedSizeThreshold = "privateStorage.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "privateStorage.virtualDiskImageCount"
        static let virtualDiskFormat = "privateStorage.virtualDiskFormat"
        static let virtualDiskSparseState = "privateStorage.virtualDiskSparseState"
        static let managementKind = "privateStorage.managementKind"
        static let sizeKnowledge = "privateStorage.sizeKnowledge"
        static let canonicalUserFacingPath = "privateStorage.canonicalUserFacingPath"
    }

    static let storageCategoryIdentifier = "private-storage"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824
    static let defaultPrivateURL = URL(fileURLWithPath: "/private", isDirectory: true)

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

    private let privateURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64

    init(
        privateURL: URL = PrivateStorageAnalyzer.defaultPrivateURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = PrivateStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.privateURL = privateURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> StorageAnalysisResult {
        let scannedResult = await scanner.scan(root: privateURL)
        let threshold = largeAllocatedSizeThreshold

        return await Task.detached(priority: .utility) {
            Self.enrich(
                scannedResult,
                largeAllocatedSizeThreshold: threshold
            )
        }.value
    }
}

// Internal for a volume-boundary regression test that must not create a
// privileged test mount.
extension PrivateStorageAnalyzer {
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
                message: "Private storage analysis requires a directory root.",
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
                enrichTopLevelChild(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootMetadata = root.metadata
        rootMetadata.storageCategoryIdentifier = storageCategoryIdentifier
        rootMetadata.explanation = "Critical system and application storage in /private."
        rootMetadata.attributes[MetadataKey.directChildCount] = String(entries.count)
        rootMetadata.attributes[MetadataKey.canonicalUserFacingPath] = root.absolutePath
        rootMetadata.attributes[MetadataKey.managementKind] = PrivateStorageManagementKind.systemManaged.rawValue

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

// MARK: - Category and Tree Enrichment

private extension PrivateStorageAnalyzer {
    static func enrichTopLevelChild(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let category = topLevelCategory(for: node)
        var children = node.children
        if category == .variableState {
            children = children
                .map {
                    enrichVarChild(
                        $0,
                        largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
                    )
                }
                .sorted(by: allocatedSizeDescending)
        }

        let withDrillDown = copy(node, children: children, metadata: node.metadata)
        return addCategoryMetadata(
            to: withDrillDown,
            category: category,
            managementKind: managementKind(for: category),
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
        )
    }

    static func enrichVarChild(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let category = varCategory(for: node)
        return addCategoryMetadata(
            to: node,
            category: category,
            managementKind: managementKind(for: category),
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
        )
    }

    static func addCategoryMetadata(
        to node: StorageNode,
        category: PrivateStorageCategory,
        managementKind: PrivateStorageManagementKind,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        var metadata = node.metadata
        metadata.storageCategoryIdentifier = category.rawValue
        metadata.isUnusuallyLarge = node.allocatedSize >= largeAllocatedSizeThreshold
        metadata.explanation = category.explanation
        metadata.attributes[MetadataKey.directChildCount] = String(node.children.count)
        metadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        metadata.attributes[MetadataKey.virtualDiskImageCount] = String(countVirtualDiskImages(in: node))
        metadata.attributes[MetadataKey.managementKind] = managementKind.rawValue
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

    static func topLevelCategory(for node: StorageNode) -> PrivateStorageCategory {
        guard node.itemType == .directory || node.itemType == .volumeBoundary else {
            return .otherTopLevel
        }
        switch node.name {
        case "var": return .variableState
        case "tmp": return .temporary
        case "etc": return .configuration
        default: return .otherTopLevel
        }
    }

    static func varCategory(for node: StorageNode) -> PrivateStorageCategory {
        guard node.itemType == .directory || node.itemType == .volumeBoundary else {
            return .otherVarChild
        }
        switch node.name {
        case "folders": return .varFolders
        case "vm": return .varVirtualMemory
        case "db": return .varDatabases
        case "log": return .varLogs
        case "tmp": return .varTemporary
        case "run": return .varRuntime
        case "root": return .varRoot
        case "protected": return .varProtected
        case "audit": return .varAudit
        default: return .otherVarChild
        }
    }

    static func managementKind(
        for category: PrivateStorageCategory
    ) -> PrivateStorageManagementKind {
        switch category {
        case .variableState, .varFolders:
            return .applicationAndSystemState
        case .temporary, .varTemporary:
            return .temporaryStorage
        case .configuration:
            return .systemConfiguration
        case .varVirtualMemory, .varDatabases, .varRoot, .varProtected, .varAudit:
            return .protectedSystemState
        case .varLogs, .varRuntime:
            return .systemManaged
        case .otherTopLevel, .otherVarChild:
            return .unclassified
        }
    }

    static func sizeKnowledge(
        for accessibility: StorageAccessibility
    ) -> PrivateStorageSizeKnowledge {
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
