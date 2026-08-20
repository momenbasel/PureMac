import Darwin
import Foundation

/// Canonical developer and third-party locations analyzed by this report.
enum DeveloperSystemCanonicalRoot: String, Codable, CaseIterable, Sendable {
    case opt = "/opt"
    case usrLocal = "/usr/local"
}

/// Availability of one configured canonical-root analysis.
enum DeveloperSystemRootState: String, Codable, Sendable {
    case present
    case missing
    case inaccessible
    case invalid
    case partiallyReadable
    case cancelled
}

/// Explanatory storage attribution only. These categories do not express
/// cleanup safety or deletion eligibility.
enum DeveloperSystemStorageCategory: String, Codable, CaseIterable, Sendable {
    case developerToolStorage
    case packageManagerStorage
    case thirdPartyStorage
    case executableStorage
    case libraryStorage
    case sharedResourceStorage
    case unknown

    var explanation: String {
        switch self {
        case .developerToolStorage:
            return "Developer tools, runtimes, SDKs, and related local storage."
        case .packageManagerStorage:
            return "Package-manager installations and data; this label does not imply cleanability."
        case .thirdPartyStorage:
            return "Third-party software and data stored outside the macOS system directories."
        case .executableStorage:
            return "Locally installed command-line executables and symbolic links."
        case .libraryStorage:
            return "Third-party and locally installed libraries."
        case .sharedResourceStorage:
            return "Shared resources installed by third-party software and developer tools."
        case .unknown:
            return "Unclassified storage retained for inspection without guessed attribution."
        }
    }
}

/// Whether a numeric subtree total is complete. An incomplete total is a
/// known lower bound and never treats unreadable descendants as known zero.
enum DeveloperSystemSizeKnowledge: String, Codable, Sendable {
    case complete
    case knownLowerBound
    case unavailable
    case incompleteDueToCancellation
    case excludedDifferentVolume
}

struct DeveloperSystemRootAnalysis: Hashable, Codable, Sendable {
    let canonicalRoot: DeveloperSystemCanonicalRoot
    let configuredPath: String
    let state: DeveloperSystemRootState
    let result: StorageAnalysisResult
}

/// Separate canonical trees plus non-additive, cross-root unique totals.
struct DeveloperSystemStorageReport: Hashable, Codable, Sendable {
    let opt: DeveloperSystemRootAnalysis
    let usrLocal: DeveloperSystemRootAnalysis
    let combinedUniqueLogicalSize: Int64
    let combinedUniqueAllocatedSize: Int64
    let combinedSizeKnowledge: DeveloperSystemSizeKnowledge
    let wasCancelled: Bool
    let issues: [StorageScanIssue]
}

/// Read-only filesystem attribution for `/opt` and `/usr/local`.
///
/// `FileTreeScanner` owns traversal, byte accounting, hard-link identity,
/// cancellation, symlink safety, and mounted-filesystem boundaries. This
/// analyzer keeps the two canonical results separate and adds only lightweight
/// path-name metadata.
struct DeveloperSystemStorageAnalyzer: Sendable {
    enum MetadataKey {
        static let canonicalRoot = "developerSystem.canonicalRoot"
        static let configuredPath = "developerSystem.configuredPath"
        static let rootState = "developerSystem.rootState"
        static let directChildCount = "developerSystem.directChildCount"
        static let largeAllocatedSizeThreshold = "developerSystem.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "developerSystem.virtualDiskImageCount"
        static let virtualDiskFormat = "developerSystem.virtualDiskFormat"
        static let virtualDiskSparseState = "developerSystem.virtualDiskSparseState"
        static let sizeKnowledge = "developerSystem.sizeKnowledge"
        static let accountingScope = "developerSystem.accountingScope"
    }

    static let defaultOptURL = URL(fileURLWithPath: "/opt", isDirectory: true)
    static let defaultUsrLocalURL = URL(fileURLWithPath: "/usr/local", isDirectory: true)
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824

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

    private let optURL: URL
    private let usrLocalURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64

    init(
        optURL: URL = DeveloperSystemStorageAnalyzer.defaultOptURL,
        usrLocalURL: URL = DeveloperSystemStorageAnalyzer.defaultUsrLocalURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = DeveloperSystemStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.optURL = optURL
        self.usrLocalURL = usrLocalURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> DeveloperSystemStorageReport {
        let scan = await scanner.scanIndependentRoots([optURL, usrLocalURL])
        let optResult = scan.results[0]
        let usrLocalResult = scan.results[1]
        let threshold = largeAllocatedSizeThreshold

        return await Task.detached(priority: .utility) {
            Self.makeReport(
                optResult: optResult,
                usrLocalResult: usrLocalResult,
                combinedUniqueLogicalSize: scan.combinedUniqueLogicalSize,
                combinedUniqueAllocatedSize: scan.combinedUniqueAllocatedSize,
                largeAllocatedSizeThreshold: threshold
            )
        }.value
    }
}

// Internal so tests can verify enrichment and filesystem-boundary behavior
// without requiring privileged mounts or access to the real canonical roots.
extension DeveloperSystemStorageAnalyzer {
    static func makeReport(
        optResult: StorageAnalysisResult,
        usrLocalResult: StorageAnalysisResult,
        combinedUniqueLogicalSize: Int64,
        combinedUniqueAllocatedSize: Int64,
        largeAllocatedSizeThreshold: Int64
    ) -> DeveloperSystemStorageReport {
        let opt = enrichRoot(
            optResult,
            canonicalRoot: .opt,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
        )
        let usrLocal = enrichRoot(
            usrLocalResult,
            canonicalRoot: .usrLocal,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
        )
        let allIssues = (opt.result.issues + usrLocal.result.issues)
            .uniqued()
            .sorted(by: issueSort)
        let wasCancelled = opt.result.wasCancelled || usrLocal.result.wasCancelled

        return DeveloperSystemStorageReport(
            opt: opt,
            usrLocal: usrLocal,
            combinedUniqueLogicalSize: combinedUniqueLogicalSize,
            combinedUniqueAllocatedSize: combinedUniqueAllocatedSize,
            combinedSizeKnowledge: combinedKnowledge(
                opt: opt,
                usrLocal: usrLocal,
                wasCancelled: wasCancelled
            ),
            wasCancelled: wasCancelled,
            issues: allIssues
        )
    }
}

// MARK: - Root and Attribution Enrichment

private extension DeveloperSystemStorageAnalyzer {
    static func enrichRoot(
        _ input: StorageAnalysisResult,
        canonicalRoot: DeveloperSystemCanonicalRoot,
        largeAllocatedSizeThreshold: Int64
    ) -> DeveloperSystemRootAnalysis {
        var root = input.root
        var issues = input.issues

        if root.itemType != .directory, root.itemType != .unknown {
            let issue = StorageScanIssue(
                path: root.absolutePath,
                kind: .notDirectory,
                message: "Developer system storage analysis requires a directory root.",
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
        let children = root.children
            .map {
                enrichImmediateChild(
                    $0,
                    canonicalRoot: canonicalRoot,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
                )
            }
            .sorted(by: allocatedSizeDescending)

        let state = rootState(for: root, result: input)
        let rootCategory: DeveloperSystemStorageCategory = canonicalRoot == .opt
            ? .thirdPartyStorage
            : .developerToolStorage
        var metadata = root.metadata
        metadata.storageCategoryIdentifier = rootCategory.rawValue
        metadata.explanation = rootCategory.explanation
        metadata.attributes[MetadataKey.canonicalRoot] = canonicalRoot.rawValue
        metadata.attributes[MetadataKey.configuredPath] = root.absolutePath
        metadata.attributes[MetadataKey.rootState] = state.rawValue
        metadata.attributes[MetadataKey.directChildCount] = String(children.count)
        metadata.attributes[MetadataKey.accountingScope] = "standalone-canonical-root"
        metadata.attributes[MetadataKey.sizeKnowledge] = rootSizeKnowledge(
            for: state
        ).rawValue
        root = copy(root, children: children, metadata: metadata)

        let result = StorageAnalysisResult(
            root: root,
            startedAt: input.startedAt,
            completedAt: input.completedAt,
            rootDeviceIdentifier: input.rootDeviceIdentifier,
            wasCancelled: input.wasCancelled,
            issues: issues.sorted(by: issueSort)
        )
        return DeveloperSystemRootAnalysis(
            canonicalRoot: canonicalRoot,
            configuredPath: root.absolutePath,
            state: state,
            result: result
        )
    }

    static func enrichImmediateChild(
        _ node: StorageNode,
        canonicalRoot: DeveloperSystemCanonicalRoot,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let category = category(for: node.name, under: canonicalRoot)
        var metadata = node.metadata
        metadata.storageCategoryIdentifier = category.rawValue
        metadata.explanation = explanation(
            for: category,
            name: node.name,
            canonicalRoot: canonicalRoot
        )
        metadata.isUnusuallyLarge = node.allocatedSize >= largeAllocatedSizeThreshold
        metadata.attributes[MetadataKey.directChildCount] = String(node.children.count)
        metadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(
            largeAllocatedSizeThreshold
        )
        metadata.attributes[MetadataKey.virtualDiskImageCount] = String(
            countVirtualDiskImages(in: node)
        )
        return copy(node, children: node.children, metadata: metadata)
    }

    static func enrichTreeMetadata(in node: StorageNode) -> StorageNode {
        let children = node.children.map(enrichTreeMetadata)
        var metadata = node.metadata
        metadata.attributes[MetadataKey.sizeKnowledge] = sizeKnowledge(for: node).rawValue

        if let format = virtualDiskFormat(for: node) {
            metadata.attributes[MetadataKey.virtualDiskFormat] = format.rawValue
            metadata.attributes[MetadataKey.virtualDiskSparseState] = sparseState(for: node).rawValue
        }

        return copy(node, children: children, metadata: metadata)
    }

    static func category(
        for name: String,
        under canonicalRoot: DeveloperSystemCanonicalRoot
    ) -> DeveloperSystemStorageCategory {
        switch (canonicalRoot, name) {
        case (.opt, "homebrew"),
             (.usrLocal, "Homebrew"),
             (.usrLocal, "Cellar"),
             (.usrLocal, "Caskroom"):
            return .packageManagerStorage
        case (.usrLocal, "bin"):
            return .executableStorage
        case (.usrLocal, "lib"):
            return .libraryStorage
        case (.usrLocal, "share"):
            return .sharedResourceStorage
        default:
            return .unknown
        }
    }

    static func explanation(
        for category: DeveloperSystemStorageCategory,
        name: String,
        canonicalRoot: DeveloperSystemCanonicalRoot
    ) -> String {
        switch (canonicalRoot, name) {
        case (.opt, "homebrew"):
            return "Homebrew installation and package storage under /opt; no cleanup behavior is implied."
        case (.usrLocal, "Homebrew"):
            return "Homebrew installation and repository storage under /usr/local; no cleanup behavior is implied."
        case (.usrLocal, "Cellar"):
            return "Installed Homebrew formula versions; no cleanup behavior is implied."
        case (.usrLocal, "Caskroom"):
            return "Homebrew Cask installation storage; no cleanup behavior is implied."
        default:
            return category.explanation
        }
    }

    static func rootState(
        for root: StorageNode,
        result: StorageAnalysisResult
    ) -> DeveloperSystemRootState {
        if result.wasCancelled || root.accessibility == .cancelled { return .cancelled }
        if root.itemType != .directory, root.itemType != .unknown { return .invalid }
        if root.itemType == .unknown,
           root.scanIssues.contains(where: { $0.posixErrorCode == ENOENT }) {
            return .missing
        }

        switch root.accessibility {
        case .accessible: return .present
        case .partiallyAccessible, .skippedDifferentVolume: return .partiallyReadable
        case .inaccessible: return .inaccessible
        case .cancelled: return .cancelled
        }
    }

    static func sizeKnowledge(for node: StorageNode) -> DeveloperSystemSizeKnowledge {
        switch node.accessibility {
        case .accessible: return .complete
        case .partiallyAccessible, .inaccessible: return .knownLowerBound
        case .cancelled: return .incompleteDueToCancellation
        case .skippedDifferentVolume: return .excludedDifferentVolume
        }
    }

    static func combinedKnowledge(
        opt: DeveloperSystemRootAnalysis,
        usrLocal: DeveloperSystemRootAnalysis,
        wasCancelled: Bool
    ) -> DeveloperSystemSizeKnowledge {
        if wasCancelled { return .incompleteDueToCancellation }
        let states = [opt.state, usrLocal.state]
        if states.contains(.inaccessible) || states.contains(.partiallyReadable) {
            return .knownLowerBound
        }
        if states.contains(.invalid) { return .unavailable }
        return .complete
    }

    static func rootSizeKnowledge(
        for state: DeveloperSystemRootState
    ) -> DeveloperSystemSizeKnowledge {
        switch state {
        case .present, .missing: return .complete
        case .inaccessible, .partiallyReadable: return .knownLowerBound
        case .invalid: return .unavailable
        case .cancelled: return .incompleteDueToCancellation
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
