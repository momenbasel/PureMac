import Foundation

enum UserHomeStandardDirectory: String, Codable, CaseIterable, Sendable {
    case desktop = "Desktop"
    case documents = "Documents"
    case downloads = "Downloads"
    case movies = "Movies"
    case music = "Music"
    case pictures = "Pictures"
    case `public` = "Public"
}

enum UserHomeStandardDirectoryState: String, Codable, Sendable {
    case present
    case missing
}

struct UserHomeStandardDirectoryStatus: Hashable, Codable, Sendable {
    let directory: UserHomeStandardDirectory
    let absolutePath: String
    let state: UserHomeStandardDirectoryState
}

struct UserHomeStorageRoot: Identifiable, Hashable, Codable, Sendable {
    var id: String { node.absolutePath }

    let standardDirectory: UserHomeStandardDirectory?
    let node: StorageNode
}

/// One canonical selected-children tree for ordinary visible storage in the
/// current user's home directory. The home directory object's own bytes are
/// excluded by FileTreeScanner; only the selected roots contribute.
struct UserHomeStorageReport: Hashable, Codable, Sendable {
    let homeDirectoryPath: String
    let roots: [UserHomeStorageRoot]
    let standardDirectories: [UserHomeStandardDirectoryStatus]
    let excludedCanonicalPaths: [String]
    let result: StorageAnalysisResult
    let combinedUniqueLogicalSize: Int64
    let combinedUniqueAllocatedSize: Int64
    let wasCancelled: Bool
    let issues: [StorageScanIssue]
}

/// Read-only analysis of visible immediate children of the user's home.
///
/// The scanner enumerates the home once and recursively traverses accepted
/// children with a shared hard-link ledger. Hidden top-level entries and the
/// complete `~/Library` tree are intentionally excluded. Hidden descendants
/// inside an accepted visible root remain part of that root's hierarchy.
struct UserHomeStorageAnalyzer: Sendable {
    enum MetadataKey {
        static let directChildCount = "userHome.directChildCount"
        static let rootKind = "userHome.rootKind"
        static let standardDirectory = "userHome.standardDirectory"
        static let largeAllocatedSizeThreshold = "userHome.largeAllocatedSizeThreshold"
        static let localDiskAccounting = "userHome.localDiskAccounting"
    }

    static let storageCategoryIdentifier = "user-home-visible-storage"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824

    static var currentUserHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private let homeDirectoryURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64

    init(
        homeDirectoryURL: URL = UserHomeStorageAnalyzer.currentUserHomeURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = UserHomeStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> UserHomeStorageReport {
        let home = homeDirectoryURL
        let libraryPath = home
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL.path
        let scanned = await scanner.scanSelectedImmediateChildren(root: home) { child in
            !child.isHidden
                && URL(fileURLWithPath: child.absolutePath).standardizedFileURL.path != libraryPath
        }
        let threshold = largeAllocatedSizeThreshold

        return await Task.detached(priority: .utility) {
            Self.makeReport(
                scanned,
                homeDirectoryURL: home,
                largeAllocatedSizeThreshold: threshold
            )
        }.value
    }
}

// Internal so tests can verify enrichment without scanning a real home.
extension UserHomeStorageAnalyzer {
    static func makeReport(
        _ input: StorageAnalysisResult,
        homeDirectoryURL: URL,
        largeAllocatedSizeThreshold: Int64
    ) -> UserHomeStorageReport {
        let home = homeDirectoryURL.standardizedFileURL
        let enrichedRoots = input.root.children.map {
            enrichRoot(
                $0,
                homeDirectoryURL: home,
                largeAllocatedSizeThreshold: largeAllocatedSizeThreshold
            )
        }.sorted(by: allocatedSizeDescending)

        var rootMetadata = input.root.metadata
        rootMetadata.storageCategoryIdentifier = storageCategoryIdentifier
        rootMetadata.explanation = "Ordinary visible storage directly below the user's home directory."
        rootMetadata.attributes[MetadataKey.directChildCount] = String(enrichedRoots.count)
        rootMetadata.attributes[MetadataKey.localDiskAccounting] = "allocated-size-only"
        let root = copy(input.root, children: enrichedRoots, metadata: rootMetadata)
        let result = StorageAnalysisResult(
            root: root,
            startedAt: input.startedAt,
            completedAt: input.completedAt,
            rootDeviceIdentifier: input.rootDeviceIdentifier,
            wasCancelled: input.wasCancelled,
            issues: input.issues
        )
        let roots = enrichedRoots.map {
            UserHomeStorageRoot(
                standardDirectory: standardDirectory(
                    for: $0.absolutePath,
                    homeDirectoryURL: home
                ),
                node: $0
            )
        }
        let presentPaths = Set(enrichedRoots.map { standardizedPath($0.absolutePath) })
        let standardDirectories = UserHomeStandardDirectory.allCases.map { directory in
            let path = home
                .appendingPathComponent(directory.rawValue, isDirectory: true)
                .standardizedFileURL.path
            return UserHomeStandardDirectoryStatus(
                directory: directory,
                absolutePath: path,
                state: presentPaths.contains(path) ? .present : .missing
            )
        }

        return UserHomeStorageReport(
            homeDirectoryPath: home.path,
            roots: roots,
            standardDirectories: standardDirectories,
            excludedCanonicalPaths: excludedPaths(homeDirectoryURL: home),
            result: result,
            combinedUniqueLogicalSize: max(root.logicalSize, 0),
            combinedUniqueAllocatedSize: max(root.allocatedSize, 0),
            wasCancelled: input.wasCancelled,
            issues: input.issues
        )
    }
}

private extension UserHomeStorageAnalyzer {
    static func enrichRoot(
        _ node: StorageNode,
        homeDirectoryURL: URL,
        largeAllocatedSizeThreshold: Int64
    ) -> StorageNode {
        let standard = standardDirectory(
            for: node.absolutePath,
            homeDirectoryURL: homeDirectoryURL
        )
        var metadata = node.metadata
        metadata.storageCategoryIdentifier = standard.map {
            "\(storageCategoryIdentifier).\($0.rawValue.lowercased())"
        } ?? "\(storageCategoryIdentifier).custom"
        metadata.isUnusuallyLarge = node.allocatedSize >= largeAllocatedSizeThreshold
        metadata.explanation = standard.map {
            "Visible user storage in the \($0.rawValue) folder; no cleanup classification is implied."
        } ?? "Visible custom user storage; no cleanup classification is implied."
        metadata.attributes[MetadataKey.directChildCount] = String(node.children.count)
        metadata.attributes[MetadataKey.rootKind] = standard == nil ? "custom" : "standard"
        metadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(
            largeAllocatedSizeThreshold
        )
        metadata.attributes[MetadataKey.localDiskAccounting] = "allocated-size-only"
        if let standard {
            metadata.attributes[MetadataKey.standardDirectory] = standard.rawValue
        }
        return copy(node, children: node.children, metadata: metadata)
    }

    static func standardDirectory(
        for path: String,
        homeDirectoryURL: URL
    ) -> UserHomeStandardDirectory? {
        let candidate = standardizedPath(path)
        return UserHomeStandardDirectory.allCases.first { directory in
            homeDirectoryURL
                .appendingPathComponent(directory.rawValue, isDirectory: true)
                .standardizedFileURL.path == candidate
        }
    }

    static func excludedPaths(homeDirectoryURL: URL) -> [String] {
        let library = homeDirectoryURL.appendingPathComponent("Library", isDirectory: true)
        return [
            library,
            library.appendingPathComponent("Application Support", isDirectory: true),
            library.appendingPathComponent("Containers", isDirectory: true),
            library.appendingPathComponent("Group Containers", isDirectory: true),
        ].map { $0.standardizedFileURL.path }
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
            accessibility: node.accessibility,
            scanIssues: node.scanIssues,
            isHidden: node.isHidden,
            isSymbolicLink: node.isSymbolicLink,
            isCountedInParentTotals: node.isCountedInParentTotals,
            metadata: metadata
        )
    }
}
