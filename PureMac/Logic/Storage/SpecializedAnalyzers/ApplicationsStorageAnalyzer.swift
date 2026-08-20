import Darwin
import Foundation

/// Explanatory categories for immediate children of the system-wide
/// `/Applications` directory. Categories describe storage role only and have
/// no uninstall, cleanup, or mutation meaning.
enum ApplicationsStorageCategory: String, Codable, CaseIterable, Sendable {
    case applicationBundle = "applications.bundle"
    case utilityFolder = "applications.utilities"
    case systemComponent = "applications.system"
    case developerTool = "applications.developer"
    case other = "applications.other"

    var explanation: String {
        switch self {
        case .applicationBundle:
            return "Installed macOS application bundle (.app)."
        case .utilityFolder:
            return "System and administrative utility applications."
        case .systemComponent:
            return "System-provided application components and helpers."
        case .developerTool:
            return "Developer IDEs, simulators, command line tools, and support apps."
        case .other:
            return "Other items located directly within /Applications."
        }
    }
}

/// Read-only storage analyzer for the canonical `/Applications` root on macOS.
///
/// `FileTreeScanner` owns filesystem traversal, allocated physical block
/// accounting (`st_blocks * 512`), logical file size measurement (`st_size`),
/// hard-link deduplication, volume-boundary protection, and error capture.
///
/// This analyzer validates root existence, enriches top-level application
/// nodes with explanatory category metadata, and sorts children deterministically.
struct ApplicationsStorageAnalyzer: Sendable {
    enum MetadataKey {
        static let directChildCount = "applications.directChildCount"
        static let largeAllocatedSizeThreshold = "applications.largeAllocatedSizeThreshold"
        static let storageScope = "applications.storageScope"
        static let canonicalUserFacingPath = "applications.canonicalUserFacingPath"
        static let packagesAggregated = "applications.packagesAggregated"
        static let descendantEntriesMeasured = "applications.descendantEntriesMeasured"
        static let descendantNodesAvoided = "applications.descendantNodesAvoided"
    }

    static let storageCategoryIdentifier = "applications"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824 // 1 GB
    static let defaultApplicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private let applicationsURL: URL
    private let scanner: FileTreeScanner
    private let cache: StorageAnalysisCache?
    private let largeAllocatedSizeThreshold: Int64

    init(
        applicationsURL: URL = ApplicationsStorageAnalyzer.defaultApplicationsURL,
        scanner: FileTreeScanner = FileTreeScanner(configuration: .init(aggregateApplicationPackages: true)),
        cache: StorageAnalysisCache? = nil,
        largeAllocatedSizeThreshold: Int64 = ApplicationsStorageAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.applicationsURL = applicationsURL
        self.scanner = scanner
        self.cache = cache
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
    }

    func analyze() async -> StorageAnalysisResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationsURL.path, isDirectory: &isDirectory) else {
            var missingMetadata = StorageAnalysisMetadata()
            missingMetadata.storageCategoryIdentifier = Self.storageCategoryIdentifier
            missingMetadata.attributes[MetadataKey.canonicalUserFacingPath] = "/Applications"

            let missingNode = StorageNode(
                name: applicationsURL.lastPathComponent.isEmpty ? "Applications" : applicationsURL.lastPathComponent,
                absolutePath: applicationsURL.path,
                logicalSize: 0,
                allocatedSize: 0,
                ownLogicalSize: 0,
                ownAllocatedSize: 0,
                itemType: .directory,
                children: [],
                accessibility: .accessible,
                scanIssues: [],
                isHidden: false,
                isSymbolicLink: false,
                isCountedInParentTotals: true,
                metadata: missingMetadata
            )
            return StorageAnalysisResult(
                root: missingNode,
                startedAt: Date(),
                completedAt: Date(),
                rootDeviceIdentifier: nil,
                wasCancelled: false,
                issues: []
            )
        }

        let scannedResult: StorageAnalysisResult
        if let cached = cache?.get(path: applicationsURL.path) {
            scannedResult = cached
        } else {
            let result = await scanner.scan(root: applicationsURL, aggregateApplicationPackages: true)
            cache?.store(result, isFullSubtree: true)
            scannedResult = result
        }

        let sortedChildren = scannedResult.root.children
            .map { enrichChild($0) }
            .sorted(by: childSortOrder)

        var rootMetadata = scannedResult.root.metadata
        rootMetadata.storageCategoryIdentifier = Self.storageCategoryIdentifier
        rootMetadata.attributes[MetadataKey.directChildCount] = String(sortedChildren.count)
        rootMetadata.attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        rootMetadata.attributes[MetadataKey.canonicalUserFacingPath] = "/Applications"
        let appCount = sortedChildren.filter { $0.name.hasSuffix(".app") }.count
        if appCount > 0 {
            rootMetadata.attributes[MetadataKey.packagesAggregated] = String(appCount)
        }
        if let measured = scannedResult.root.metadata.attributes["fileTreeScanner.descendantEntriesMeasured"] {
            rootMetadata.attributes[MetadataKey.descendantEntriesMeasured] = measured
            rootMetadata.attributes[MetadataKey.descendantNodesAvoided] = measured
        }

        let enrichedRoot = StorageNode(
            name: scannedResult.root.name,
            absolutePath: scannedResult.root.absolutePath,
            logicalSize: scannedResult.root.logicalSize,
            allocatedSize: scannedResult.root.allocatedSize,
            ownLogicalSize: scannedResult.root.ownLogicalSize,
            ownAllocatedSize: scannedResult.root.ownAllocatedSize,
            itemType: scannedResult.root.itemType,
            children: sortedChildren,
            accessibility: scannedResult.root.accessibility,
            scanIssues: scannedResult.root.scanIssues,
            isHidden: scannedResult.root.isHidden,
            isSymbolicLink: scannedResult.root.isSymbolicLink,
            isCountedInParentTotals: scannedResult.root.isCountedInParentTotals,
            metadata: rootMetadata
        )

        return StorageAnalysisResult(
            root: enrichedRoot,
            startedAt: scannedResult.startedAt,
            completedAt: scannedResult.completedAt,
            rootDeviceIdentifier: scannedResult.rootDeviceIdentifier,
            wasCancelled: scannedResult.wasCancelled,
            issues: scannedResult.issues
        )
    }

    private func enrichChild(_ node: StorageNode) -> StorageNode {
        let category = categoryFor(name: node.name, path: node.absolutePath)
        var metadata = node.metadata
        metadata.storageCategoryIdentifier = category.rawValue
        metadata.explanation = category.explanation

        return StorageNode(
            name: node.name,
            absolutePath: node.absolutePath,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            ownLogicalSize: node.ownLogicalSize,
            ownAllocatedSize: node.ownAllocatedSize,
            itemType: node.itemType,
            children: node.children,
            accessibility: node.accessibility,
            scanIssues: node.scanIssues,
            isHidden: node.isHidden,
            isSymbolicLink: node.isSymbolicLink,
            isCountedInParentTotals: node.isCountedInParentTotals,
            metadata: metadata
        )
    }

    private func categoryFor(name: String, path: String) -> ApplicationsStorageCategory {
        if name.hasSuffix(".app") {
            if name.contains("Xcode") || name.contains("Developer") {
                return .developerTool
            }
            if name.contains("Safari") || name.contains("System") || name.contains("Finder") {
                return .systemComponent
            }
            return .applicationBundle
        }
        if name == "Utilities" {
            return .utilityFolder
        }
        return .other
    }

    private func childSortOrder(_ lhs: StorageNode, _ rhs: StorageNode) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
