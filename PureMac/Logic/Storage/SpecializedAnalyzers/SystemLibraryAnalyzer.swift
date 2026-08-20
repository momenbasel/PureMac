import Darwin
import Foundation

/// Explanatory categories for immediate children of the system-wide
/// `/Library` directory. Categories describe storage; they never imply that
/// the represented files are safe to remove.
enum SystemLibraryStorageCategory: String, Codable, CaseIterable, Sendable {
    case applicationSupport = "system-library.application-support"
    case caches = "system-library.caches"
    case developer = "system-library.developer"
    case logs = "system-library.logs"
    case frameworks = "system-library.frameworks"
    case launchAgents = "system-library.launch-agents"
    case launchDaemons = "system-library.launch-daemons"
    case privilegedHelperTools = "system-library.privileged-helper-tools"
    case preferences = "system-library.preferences"
    case extensions = "system-library.extensions"
    case updates = "system-library.updates"
    case audio = "system-library.audio"
    case fonts = "system-library.fonts"
    case other = "system-library.other"

    var explanation: String {
        switch self {
        case .applicationSupport:
            return "System-wide shared application data and support files."
        case .caches:
            return "System-wide cache storage; this label does not classify its contents as disposable."
        case .developer:
            return "System-wide developer tools, support files, and related components."
        case .logs:
            return "System-wide application and service logs."
        case .frameworks:
            return "Frameworks shared by applications and system-wide components."
        case .launchAgents:
            return "Definitions for system-wide per-user background agents."
        case .launchDaemons:
            return "Definitions for system-wide background daemons."
        case .privilegedHelperTools:
            return "Privileged helper executables installed for applications or services."
        case .preferences:
            return "System-wide application and service preferences."
        case .extensions:
            return "System-wide extensions and driver-related components."
        case .updates:
            return "System-wide update support and staged update data."
        case .audio:
            return "System-wide audio plug-ins, presets, and support data."
        case .fonts:
            return "Fonts available system-wide."
        case .other:
            return "Other storage directly inside the system-wide Library directory."
        }
    }
}

/// Read-only storage analysis of the macOS Data-volume `/Library` path.
///
/// Filesystem traversal, volume-boundary enforcement, hard-link accounting,
/// and error capture remain exclusively owned by `FileTreeScanner`. This
/// analyzer only validates the root's semantic role, orders immediate
/// children, and adds explanatory metadata for future drill-down UI.
struct SystemLibraryAnalyzer: Sendable {
    enum MetadataKey {
        static let directChildCount = "systemLibrary.directChildCount"
        static let largeAllocatedSizeThreshold = "systemLibrary.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "systemLibrary.virtualDiskImageCount"
        static let virtualDiskFormat = "systemLibrary.virtualDiskFormat"
        static let virtualDiskSparseState = "systemLibrary.virtualDiskSparseState"
        static let storageScope = "systemLibrary.storageScope"
        static let canonicalUserFacingPath = "systemLibrary.canonicalUserFacingPath"
    }

    static let storageCategoryIdentifier = "system-library"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824
    static let defaultSystemLibraryURL = URL(fileURLWithPath: "/Library", isDirectory: true)

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

    private let systemLibraryURL: URL
    private let scanner: FileTreeScanner
    private let cache: StorageAnalysisCache?
    private let largeAllocatedSizeThreshold: Int64

    init(
        systemLibraryURL: URL = SystemLibraryAnalyzer.defaultSystemLibraryURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        cache: StorageAnalysisCache? = nil,
        largeAllocatedSizeThreshold: Int64 = SystemLibraryAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.systemLibraryURL = systemLibraryURL
        self.scanner = scanner
        self.cache = cache
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> StorageAnalysisResult {
        let scannedResult: StorageAnalysisResult
        if let cached = cache?.get(path: systemLibraryURL.path) {
            scannedResult = cached
        } else {
            let result = await scanner.scan(root: systemLibraryURL)
            cache?.store(result, isFullSubtree: true)
            scannedResult = result
        }
        let threshold = largeAllocatedSizeThreshold

        return await Task.detached(priority: .utility) {
            Self.enrich(
                scannedResult,
                largeAllocatedSizeThreshold: threshold
            )
        }.value
    }
}

// Internal so tests can verify that enrichment preserves synthetic volume
// boundaries without requiring a privileged test mount.
extension SystemLibraryAnalyzer {
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
                message: "System Library analysis requires a directory root.",
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

        let entries = root.children
            .map {
                enrichImmediateChild(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootMetadata = root.metadata
        rootMetadata.storageCategoryIdentifier = storageCategoryIdentifier
        rootMetadata.explanation = "Storage in the system-wide /Library directory."
        rootMetadata.attributes[MetadataKey.directChildCount] = String(entries.count)
        rootMetadata.attributes[MetadataKey.storageScope] = "system-wide"
        rootMetadata.attributes[MetadataKey.canonicalUserFacingPath] = root.absolutePath

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

private extension SystemLibraryAnalyzer {
    static func enrichImmediateChild(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let enrichedTree = enrichVirtualDiskMetadata(in: node)
        let category = category(for: enrichedTree)
        var metadata = enrichedTree.metadata
        metadata.storageCategoryIdentifier = category.rawValue
        metadata.isUnusuallyLarge = enrichedTree.allocatedSize >= largeAllocatedSizeThreshold
        metadata.explanation = category.explanation
        metadata.attributes[MetadataKey.directChildCount] = String(enrichedTree.children.count)
        metadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        metadata.attributes[MetadataKey.virtualDiskImageCount] = String(
            countVirtualDiskImages(in: enrichedTree)
        )
        metadata.attributes[MetadataKey.storageScope] = "system-wide"

        return copy(enrichedTree, children: enrichedTree.children, metadata: metadata)
    }

    static func enrichVirtualDiskMetadata(in node: StorageNode) -> StorageNode {
        let children = node.children.map(enrichVirtualDiskMetadata)
        var metadata = node.metadata

        if let format = virtualDiskFormat(for: node) {
            metadata.attributes[MetadataKey.virtualDiskFormat] = format.rawValue
            metadata.attributes[MetadataKey.virtualDiskSparseState] = sparseState(for: node).rawValue
        }

        return copy(node, children: children, metadata: metadata)
    }

    static func category(for node: StorageNode) -> SystemLibraryStorageCategory {
        guard node.itemType == .directory || node.itemType == .volumeBoundary else {
            return .other
        }

        switch node.name {
        case "Application Support": return .applicationSupport
        case "Caches": return .caches
        case "Developer": return .developer
        case "Logs": return .logs
        case "Frameworks": return .frameworks
        case "LaunchAgents": return .launchAgents
        case "LaunchDaemons": return .launchDaemons
        case "PrivilegedHelperTools": return .privilegedHelperTools
        case "Preferences": return .preferences
        case "Extensions": return .extensions
        case "Updates": return .updates
        case "Audio": return .audio
        case "Fonts": return .fonts
        default: return .other
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
