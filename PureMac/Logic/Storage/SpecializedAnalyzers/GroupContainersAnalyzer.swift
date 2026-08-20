import Foundation

/// Read-only analysis of the current user's `~/Library/Group Containers`.
///
/// `FileTreeScanner` remains responsible for traversal, byte accounting,
/// volume boundaries, links, errors, and cancellation. This analyzer only
/// adds shared-container metadata and presentation ordering to that tree.
struct GroupContainersAnalyzer: Sendable {
    /// Supplies relationships established by a reliable source, such as a
    /// future entitlement index. Directory-name similarity is not evidence.
    typealias AttributionProvider = @Sendable (String) -> [StorageApplicationOwner]

    enum MetadataKey {
        static let directChildCount = "groupContainers.directChildCount"
        static let groupIdentifierSource = "groupContainers.identifierSource"
        static let largeAllocatedSizeThreshold = "groupContainers.largeAllocatedSizeThreshold"
        static let ownerCount = "groupContainers.ownerCount"
        static let virtualDiskImageCount = "groupContainers.virtualDiskImageCount"
    }

    static let storageCategoryIdentifier = "group-containers"
    static let defaultLargeAllocatedSizeThreshold: Int64 = 1_073_741_824

    static var currentUserGroupContainersURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
    }

    private static let virtualDiskImageExtensions: Set<String> = [
        "img", "qcow2", "raw", "sparsebundle", "vmdk",
    ]

    private let groupContainersURL: URL
    private let scanner: FileTreeScanner
    private let cache: StorageAnalysisCache?
    private let largeAllocatedSizeThreshold: Int64
    private let attributionProvider: AttributionProvider

    init(
        groupContainersURL: URL = GroupContainersAnalyzer.currentUserGroupContainersURL,
        scanner: FileTreeScanner = FileTreeScanner(),
        cache: StorageAnalysisCache? = nil,
        largeAllocatedSizeThreshold: Int64 = GroupContainersAnalyzer.defaultLargeAllocatedSizeThreshold
    ) {
        self.init(
            groupContainersURL: groupContainersURL,
            scanner: scanner,
            cache: cache,
            largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
            attributionProvider: { _ in [] }
        )
    }

    init(
        groupContainersURL: URL,
        scanner: FileTreeScanner = FileTreeScanner(),
        cache: StorageAnalysisCache? = nil,
        largeAllocatedSizeThreshold: Int64 = GroupContainersAnalyzer.defaultLargeAllocatedSizeThreshold,
        attributionProvider: @escaping AttributionProvider
    ) {
        self.groupContainersURL = groupContainersURL
        self.scanner = scanner
        self.cache = cache
        self.largeAllocatedSizeThreshold = max(largeAllocatedSizeThreshold, 1)
        self.attributionProvider = attributionProvider
    }

    /// Returns the scanner's complete hierarchy with immediate Group
    /// Containers ordered for storage inspection. No cleanup semantics or
    /// filesystem mutation are introduced by this analyzer.
    func analyze() async -> StorageAnalysisResult {
        let scannedResult: StorageAnalysisResult
        if let cached = cache?.get(path: groupContainersURL.path) {
            scannedResult = cached
        } else {
            let result = await scanner.scan(root: groupContainersURL)
            cache?.store(result, isFullSubtree: true)
            scannedResult = result
        }
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

private extension GroupContainersAnalyzer {
    static func enrich(
        _ result: StorageAnalysisResult,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageAnalysisResult {
        let groupContainers = result.root.children
            .map {
                enrichGroupContainer(
                    $0,
                    largeAllocatedSizeThreshold: largeAllocatedSizeThreshold,
                    attributionProvider: attributionProvider
                )
            }
            .sorted(by: allocatedSizeDescending)

        var rootAttributes = result.root.metadata.attributes
        rootAttributes[MetadataKey.directChildCount] = String(groupContainers.count)

        let rootMetadata = StorageAnalysisMetadata(
            bundleIdentifier: result.root.metadata.bundleIdentifier,
            groupContainerIdentifier: result.root.metadata.groupContainerIdentifier,
            owningApplicationIdentifier: result.root.metadata.owningApplicationIdentifier,
            owningApplicationName: result.root.metadata.owningApplicationName,
            owningApplications: result.root.metadata.owningApplications,
            storageCategoryIdentifier: storageCategoryIdentifier,
            safetyClassificationIdentifier: result.root.metadata.safetyClassificationIdentifier,
            confidence: result.root.metadata.confidence,
            isUnusuallyLarge: result.root.metadata.isUnusuallyLarge,
            explanation: "Shared application data in the current user's Group Containers directory.",
            attributes: rootAttributes
        )

        let root = copy(result.root, children: groupContainers, metadata: rootMetadata)
        return StorageAnalysisResult(
            root: root,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            rootDeviceIdentifier: result.rootDeviceIdentifier,
            wasCancelled: result.wasCancelled,
            issues: result.issues
        )
    }

    static func enrichGroupContainer(
        _ node: StorageNode,
        largeAllocatedSizeThreshold: Int64,
        attributionProvider: AttributionProvider
    ) -> StorageNode {
        let identifier = groupContainerIdentifierCandidate(for: node)
        let owners = identifier
            .map(attributionProvider)
            .map(normalizedOwners) ?? []
        let virtualDiskImageCount = countVirtualDiskImages(in: node)

        var attributes = node.metadata.attributes
        attributes[MetadataKey.directChildCount] = String(node.children.count)
        attributes[MetadataKey.largeAllocatedSizeThreshold] = String(largeAllocatedSizeThreshold)
        attributes[MetadataKey.ownerCount] = String(owners.count)
        attributes[MetadataKey.virtualDiskImageCount] = String(virtualDiskImageCount)
        if let identifier {
            attributes[MetadataKey.groupIdentifierSource] = identifierSource(identifier)
        }

        let explanation: String
        if !owners.isEmpty {
            let ownerNames = owners.map { $0.displayName ?? $0.bundleIdentifier }
            explanation = "Shared application data used by \(ownerNames.joined(separator: ", "))."
        } else if let identifier {
            explanation = "Shared application data for \(identifier); application ownership is unresolved."
        } else {
            explanation = "Shared application data; the container identifier and application ownership are unresolved."
        }

        let metadata = StorageAnalysisMetadata(
            bundleIdentifier: nil,
            groupContainerIdentifier: identifier,
            owningApplicationIdentifier: nil,
            owningApplicationName: nil,
            owningApplications: owners.isEmpty ? nil : owners,
            storageCategoryIdentifier: storageCategoryIdentifier,
            safetyClassificationIdentifier: node.metadata.safetyClassificationIdentifier,
            confidence: owners.isEmpty ? nil : 1,
            isUnusuallyLarge: node.allocatedSize >= largeAllocatedSizeThreshold,
            explanation: explanation,
            attributes: attributes
        )

        return copy(node, children: node.children, metadata: metadata)
    }

    static func normalizedOwners(
        _ owners: [StorageApplicationOwner]
    ) -> [StorageApplicationOwner] {
        var ownersByIdentifier: [String: StorageApplicationOwner] = [:]
        for owner in owners where isEntitlementIdentifier(owner.bundleIdentifier) {
            if ownersByIdentifier[owner.bundleIdentifier] == nil {
                ownersByIdentifier[owner.bundleIdentifier] = owner
            }
        }
        return ownersByIdentifier.values.sorted {
            if $0.bundleIdentifier != $1.bundleIdentifier {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return ($0.displayName ?? "") < ($1.displayName ?? "")
        }
    }

    static func groupContainerIdentifierCandidate(for node: StorageNode) -> String? {
        guard node.itemType == .directory || node.itemType == .volumeBoundary,
              isEntitlementIdentifier(node.name) else {
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

// MARK: - Identifier Recognition

private extension GroupContainersAnalyzer {
    static func isEntitlementIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard components.allSatisfy({ component in
            component.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        }) else {
            return false
        }

        if components[0] == "group" {
            return components.count >= 3
        }
        return true
    }

    static func identifierSource(_ identifier: String) -> String {
        let firstComponent = identifier.split(separator: ".", omittingEmptySubsequences: false)[0]
        if firstComponent == "group" {
            return "group-prefix-directory-name"
        }
        if isAppleTeamIdentifier(firstComponent) {
            return "team-id-prefix-directory-name"
        }
        return "entitlement-style-directory-name"
    }

    static func isAppleTeamIdentifier(_ component: Substring) -> Bool {
        guard component.count == 10 else { return false }
        let allowedCharacters = CharacterSet.uppercaseLetters.union(.decimalDigits)
        return component.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }
}
