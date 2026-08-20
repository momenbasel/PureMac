import AppKit
import Foundation

/// Read-only analysis of the current user's `~/Library/Application Support`.
///
/// The analyzer deliberately delegates all filesystem traversal and byte
/// accounting to `FileTreeScanner`. Its role is limited to Application
/// Support-specific ordering, conservative application attribution, and
/// explanatory metadata for a future storage UI.
struct ApplicationSupportAnalyzer: Sendable {
    struct ApplicationIdentity: Hashable, Sendable {
        let bundleIdentifier: String
        let displayName: String
    }

    typealias AttributionProvider = @Sendable (String) -> ApplicationIdentity?

    enum MetadataKey {
        static let directChildCount = "applicationSupport.directChildCount"
        static let largeAllocatedSizeThreshold = "applicationSupport.largeAllocatedSizeThreshold"
        static let virtualDiskImageCount = "applicationSupport.virtualDiskImageCount"
    }

    static let storageCategoryIdentifier = "application-support"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824

    static var currentUserApplicationSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private static let virtualDiskImageExtensions: Set<String> = [
        "img", "qcow2", "raw", "sparsebundle", "vmdk",
    ]

    private let applicationSupportURL: URL
    private let scanner: FileTreeScanner
    private let largeAllocatedSizeThreshold: Int64
    private let attributionProvider: AttributionProvider

    init(
        applicationSupportURL: URL = ApplicationSupportAnalyzer.currentUserApplicationSupportURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = ApplicationSupportAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.init(
            applicationSupportURL: applicationSupportURL,
            scanner: scanner,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
            attributionProvider: { directoryName in
                ApplicationSupportAnalyzer.workspaceAttribution(for: directoryName)
            }
        )
    }

    init(
        applicationSupportURL: URL,
        scanner: FileTreeScanner = FileTreeScanner(),
        largeAllocatedSizeThreshold: Int64 = ApplicationSupportAnalyzer.defaultLargeAllocatedSizeThreshold,
        attributionProvider: @escaping AttributionProvider
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.scanner = scanner
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
        self.attributionProvider = attributionProvider
    }

    /// Returns the scanner's native result model. Immediate Application
    /// Support children are ordered by allocated size, while every descendant
    /// remains available for later drill-down.
    func analyze() async -> StorageAnalysisResult {
        let scannedResult = await scanner.scan(root: applicationSupportURL)
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

private extension ApplicationSupportAnalyzer {
    static func enrich(
        _ result: StorageAnalysisResult,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageAnalysisResult {
        let entries = result.root.children
            .map {
                enrichEntry(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
                    attributionProvider: attributionProvider
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootAttributes = result.root.metadata.attributes
        rootAttributes[MetadataKey.directChildCount] = String(entries.count)

        let rootMetadata = StorageAnalysisMetadata(
            owningApplicationIdentifier: result.root.metadata.owningApplicationIdentifier,
            owningApplicationName: result.root.metadata.owningApplicationName,
            storageCategoryIdentifier: storageCategoryIdentifier,
            safetyClassificationIdentifier: result.root.metadata.safetyClassificationIdentifier,
            confidence: result.root.metadata.confidence,
            isUnusuallyLarge: result.root.metadata.isUnusuallyLarge,
            explanation: "Storage in the current user's Application Support directory.",
            attributes: rootAttributes
        )

        let root = copy(result.root, children: entries, metadata: rootMetadata)
        return StorageAnalysisResult(
            root: root,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            rootDeviceIdentifier: result.rootDeviceIdentifier,
            wasCancelled: result.wasCancelled,
            issues: result.issues
        )
    }

    static func enrichEntry(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageNode {
        let attribution = node.itemType == .directory ? attributionProvider(node.name) : nil
        let virtualDiskImageCount = countVirtualDiskImages(in: node)
        var attributes = node.metadata.attributes
        attributes[MetadataKey.directChildCount] = String(node.children.count)
        attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        attributes[MetadataKey.virtualDiskImageCount] = String(virtualDiskImageCount)

        let explanation: String
        if let attribution {
            explanation = "Storage used by \(attribution.displayName) in Application Support."
        } else {
            explanation = "Application Support storage; the owning application has not been identified."
        }

        let metadata = StorageAnalysisMetadata(
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

// MARK: - Conservative Application Attribution

private extension ApplicationSupportAnalyzer {
    /// Only reverse-DNS-style directory names are considered. Launch Services
    /// must resolve the exact identifier to an installed app, and the bundle
    /// itself must report the same identifier. Plain vendor names such as
    /// "Google" or product names such as "Code" remain unattributed unless a
    /// future provider supplies an explicit, reliable relationship.
    static func workspaceAttribution(for directoryName: String) -> ApplicationIdentity? {
        guard isBundleIdentifier(directoryName),
              let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: directoryName
              ),
              let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == directoryName else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent

        return ApplicationIdentity(
            bundleIdentifier: directoryName,
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
