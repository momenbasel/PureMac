import AppKit
import Foundation

/// Read-only analysis of the current user's `~/Library/Containers`.
///
/// Filesystem traversal and byte accounting remain the responsibility of
/// `FileTreeScanner`. This analyzer adds container-specific bundle metadata,
/// verified application attribution, and largest-first presentation ordering.
struct ContainersAnalyzer: Sendable {
    struct ApplicationIdentity: Hashable, Sendable {
        let bundleIdentifier: String
        let displayName: String
    }

    typealias AttributionProvider = @Sendable (String) -> ApplicationIdentity?

    enum MetadataKey {
        static let directChildCount = "containers.directChildCount"
        static let largeAllocatedSizeThreshold = "containers.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "containers.virtualDiskImageCount"
        static let bundleIdentifierSource = "containers.bundleIdentifierSource"
    }

    static let storageCategoryIdentifier = "containers"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824

    static var currentUserContainersURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
    }

    private static let virtualDiskImageExtensions: Set<String> = [
        "img", "qcow2", "raw", "sparsebundle", "vmdk",
    ]

    private let containersURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64
    private let attributionProvider: AttributionProvider

    init(
        containersURL: URL = ContainersAnalyzer.currentUserContainersURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = ContainersAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.init(
            containersURL: containersURL,
            scanner: scanner,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
            attributionProvider: { bundleIdentifier in
                ContainersAnalyzer.workspaceAttribution(for: bundleIdentifier)
            }
        )
    }

    init(
        containersURL: URL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = ContainersAnalyzer.defaultLargeAllocatedSizeThreshold,
        attributionProvider: @escaping AttributionProvider
    ) {
        self.containersURL = containersURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
        self.attributionProvider = attributionProvider
    }

    /// Returns the scanner's native hierarchical result. Immediate containers
    /// are ordered by allocated bytes; their complete children remain intact
    /// for future inspection of Data, Library, Documents, and other paths.
    func analyze() async -> StorageAnalysisResult {
        let scannedResult = await scanner.scan(root: containersURL)
        let threshold = largeAllocatedSizeThreshold
        let attributionProvider = attributionProvider

        return await Task.detached(priority: .utility) {
            Self.enrich(
                scannedResult,
                largeAllocatedSizeThreshold: threshold,
                attributionProvider: attributionProvider
            )
        }.value
    }
}

// MARK: - Result Enrichment

private extension ContainersAnalyzer {
    static func enrich(
        _ result: StorageAnalysisResult,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageAnalysisResult {
        let containers = result.root.children
            .map {
                enrichContainer(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
                    attributionProvider: attributionProvider
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootAttributes = result.root.metadata.attributes
        rootAttributes[MetadataKey.directChildCount] = String(containers.count)

        let rootMetadata = StorageAnalysisMetadata(
            bundleIdentifier: result.root.metadata.bundleIdentifier,
            owningApplicationIdentifier: result.root.metadata.owningApplicationIdentifier,
            owningApplicationName: result.root.metadata.owningApplicationName,
            storageCategoryIdentifier: storageCategoryIdentifier,
            safetyClassificationIdentifier: result.root.metadata.safetyClassificationIdentifier,
            confidence: result.root.metadata.confidence,
            isUnusuallyLarge: result.root.metadata.isUnusuallyLarge,
            explanation: "Sandboxed application storage in the current user's Containers directory.",
            attributes: rootAttributes
        )

        let root = copy(result.root, children: containers, metadata: rootMetadata)
        return StorageAnalysisResult(
            root: root,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            rootDeviceIdentifier: result.rootDeviceIdentifier,
            wasCancelled: result.wasCancelled,
            issues: result.issues
        )
    }

    static func enrichContainer(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageNode {
        let bundleIdentifier = bundleIdentifierCandidate(for: node)
        let proposedAttribution = bundleIdentifier.flatMap(attributionProvider)
        let attribution: ApplicationIdentity?
        if proposedAttribution?.bundleIdentifier == bundleIdentifier {
            attribution = proposedAttribution
        } else {
            attribution = nil
        }

        let virtualDiskImageCount = countVirtualDiskImages(in: node)
        var attributes = node.metadata.attributes
        attributes[MetadataKey.directChildCount] = String(node.children.count)
        attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        attributes[MetadataKey.virtualDiskImageCount] = String(virtualDiskImageCount)
        if bundleIdentifier != nil {
            attributes[MetadataKey.bundleIdentifierSource] = "directory-name"
        }

        let explanation: String
        if let attribution {
            explanation = "Sandboxed application data used by \(attribution.displayName)."
        } else if let bundleIdentifier {
            explanation = "Sandboxed application data for \(bundleIdentifier); the installed application owner is unknown."
        } else {
            explanation = "Sandboxed application data; the bundle identifier and owner are unknown."
        }

        let metadata = StorageAnalysisMetadata(
            bundleIdentifier: bundleIdentifier,
            owningApplicationIdentifier: attribution?.bundleIdentifier,
            owningApplicationName: attribution?.displayName,
            storageCategoryIdentifier: storageCategoryIdentifier,
            safetyClassificationIdentifier: node.metadata.safetyClassificationIdentifier,
            confidence: attribution == nil ? nil : 1,
            isUnusuallyLarge: node.allocatedSize >= largeAllocatedSizeThreshold,
            explanation: explanation,
            attributes: attributes
        )

        return copy(node, children: node.children, metadata: metadata)
    }

    static func bundleIdentifierCandidate(for node: StorageNode) -> String? {
        guard node.itemType == .directory || node.itemType == .volumeBoundary,
              isBundleIdentifier(node.name) else {
            return nil
        }
        return node.name
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

    static func allocatedSizeDescending(_ left: StorageNode, _ right: StorageNode) -> Bool {
        if left.allocatedSize != right.allocatedSize {
            return left.allocatedSize > right.allocatedSize
        }
        if left.logicalSize != right.logicalSize {
            return left.logicalSize > right.logicalSize
        }
        return left.absolutePath < right.absolutePath
    }

    static func countVirtualDiskImages(in root: StorageNode) -> Int {
        var count = 0
        var pending = [root]
        while let node = pending.popLast() {
            let pathExtension = URL(fileURLWithPath: node.absolutePath).pathExtension.lowercased()
            if virtualDiskImageExtensions.contains(pathExtension) {
                count += 1
            }
            pending.append(contentsOf: node.children)
        }
        return count
    }
}

// MARK: - Conservative Bundle Attribution

private extension ContainersAnalyzer {
    /// Launch Services must resolve the exact container directory identifier,
    /// and the resulting app bundle must report that same identifier. A valid
    /// directory name alone is retained as a candidate but never proves owner.
    static func workspaceAttribution(for bundleIdentifier: String) -> ApplicationIdentity? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ),
              let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == bundleIdentifier else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent

        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.allSatisfy { component in
            component.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        }
    }
}
