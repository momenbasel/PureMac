import Darwin
import Foundation

/// Builds a read-only tree of filesystem usage without producing cleanup
/// candidates or changing anything on disk.
final class FileTreeScanner: @unchecked Sendable {
    struct Configuration: Sendable {
        let maxConcurrentDirectoryReads: Int
        let aggregateApplicationPackages: Bool

        init(
            maxConcurrentDirectoryReads: Int = 8,
            aggregateApplicationPackages: Bool = false
        ) {
            self.maxConcurrentDirectoryReads = min(max(maxConcurrentDirectoryReads, 1), 16)
            self.aggregateApplicationPackages = aggregateApplicationPackages
        }
    }

    /// Read-only metadata available when choosing which immediate children of
    /// a root should receive recursive analysis.
    struct ImmediateChild: Sendable {
        let name: String
        let absolutePath: String
        let itemType: StorageItemType
        let accessibility: StorageAccessibility
        let isHidden: Bool
        let isSymbolicLink: Bool
    }

    /// Results for independent canonical roots plus totals that count a
    /// physical hard-linked file only once across the complete root set.
    /// Individual results retain their standalone per-root accounting.
    struct MultiRootAnalysis: Sendable {
        let results: [StorageAnalysisResult]
        let combinedUniqueLogicalSize: Int64
        let combinedUniqueAllocatedSize: Int64
    }

    private let configuration: Configuration
    private let cache: StorageAnalysisCache?

    init(configuration: Configuration = Configuration(), cache: StorageAnalysisCache? = nil) {
        self.configuration = configuration
        self.cache = cache
    }

    /// Scans off the calling actor. Cancelling the caller returns a partial
    /// tree whose incomplete locations are represented as scan issues.
    func scan(
        root: URL,
        aggregateApplicationPackages: Bool? = nil
    ) async -> StorageAnalysisResult {
        let shouldAggregate = aggregateApplicationPackages ?? configuration.aggregateApplicationPackages
        if let cache {
            do {
                return try await cache.scanOrCoalesce(path: root.path) {
                    await self.scanDirectly(
                        root: root,
                        immediateChildFilter: nil,
                        aggregateApplicationPackages: shouldAggregate
                    )
                }
            } catch {
                return await scanDirectly(
                    root: root,
                    immediateChildFilter: nil,
                    aggregateApplicationPackages: shouldAggregate
                )
            }
        }
        return await scanDirectly(
            root: root,
            immediateChildFilter: nil,
            aggregateApplicationPackages: shouldAggregate
        )
    }

    /// Scans independent roots in one detached operation. Each root enforces
    /// its own volume boundary and produces its own tree. The combined totals
    /// use a shared inode ledger so hard links visible in more than one root
    /// are not added twice. Symbolic links are never resolved.
    func scanIndependentRoots(_ roots: [URL]) async -> MultiRootAnalysis {
        guard !roots.isEmpty else {
            return MultiRootAnalysis(
                results: [],
                combinedUniqueLogicalSize: 0,
                combinedUniqueAllocatedSize: 0
            )
        }

        let cancellation = ScanCancellationToken()
        let configuration = configuration
        let task = Task.detached(priority: .utility) {
            Self.scanIndependentRootsSynchronously(
                roots,
                configuration: configuration,
                cancellation: cancellation
            )
        }

        let analysis = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            cancellation.cancel()
        }

        if let cache {
            for result in analysis.results {
                cache.store(result, isFullSubtree: true)
            }
        }

        return analysis
    }

    /// Enumerates the supplied root once, then recursively scans only the
    /// immediate children accepted by `include`. All selected roots share one
    /// hard-link accounting context. The returned root's subtree totals contain
    /// selected children only; the root directory's own bytes are excluded.
    func scanSelectedImmediateChildren(
        root: URL,
        aggregateApplicationPackages: Bool? = nil,
        including include: @escaping @Sendable (ImmediateChild) -> Bool
    ) async -> StorageAnalysisResult {
        let shouldAggregate = aggregateApplicationPackages ?? configuration.aggregateApplicationPackages
        return await scanDirectly(
            root: root,
            immediateChildFilter: include,
            aggregateApplicationPackages: shouldAggregate
        )
    }

    private func scanDirectly(
        root: URL,
        immediateChildFilter: (@Sendable (ImmediateChild) -> Bool)?,
        aggregateApplicationPackages: Bool
    ) async -> StorageAnalysisResult {
        let cancellation = ScanCancellationToken()
        var config = configuration
        if config.aggregateApplicationPackages != aggregateApplicationPackages {
            config = Configuration(
                maxConcurrentDirectoryReads: configuration.maxConcurrentDirectoryReads,
                aggregateApplicationPackages: aggregateApplicationPackages
            )
        }
        let task = Task.detached(priority: .utility) {
            Self.scanSynchronously(
                root: root,
                configuration: config,
                cancellation: cancellation,
                immediateChildFilter: immediateChildFilter
            )
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

// MARK: - Scan Implementation

private extension FileTreeScanner {
    struct FileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    struct FlatNode: Sendable {
        let name: String
        let path: String
        let parentPath: String?
        var itemType: StorageItemType
        let ownLogicalSize: Int64
        let ownAllocatedSize: Int64
        var aggregateLogicalSize: Int64? = nil
        var aggregateAllocatedSize: Int64? = nil
        let deviceIdentifier: UInt64?
        let inode: UInt64?
        let hardLinkCount: UInt64
        let isHidden: Bool
        let isSymbolicLink: Bool
        var isCountedInParentTotals: Bool
        var accessibility: StorageAccessibility
        var issues: [StorageScanIssue]
        var isPackageAggregate: Bool = false
    }

    struct DirectoryRead: Sendable {
        let path: String
        let entryNames: [String]
        let issue: StorageScanIssue?
        let wasCancelled: Bool
    }

    struct PackageMeasurement: Sendable {
        let logicalSize: Int64
        let allocatedSize: Int64
        let accessibility: StorageAccessibility
        let issues: [StorageScanIssue]
        let entriesMeasured: Int
    }

    struct FlatScan: Sendable {
        let rootPath: String
        let startedAt: Date
        let completedAt: Date
        let rootDeviceIdentifier: UInt64?
        let wasCancelled: Bool
        var nodesByPath: [String: FlatNode]
        var packagesAggregated: Int = 0
        var descendantEntriesMeasured: Int = 0
    }

    final class DirectoryReadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var indexedResults: [(index: Int, result: DirectoryRead)] = []

        func append(_ result: DirectoryRead, at index: Int) {
            lock.lock()
            indexedResults.append((index, result))
            lock.unlock()
        }

        func orderedResults() -> [DirectoryRead] {
            lock.lock()
            let snapshot = indexedResults
            lock.unlock()
            return snapshot.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    static func scanSynchronously(
        root: URL,
        configuration: Configuration,
        cancellation: ScanCancellationToken,
        immediateChildFilter: (@Sendable (ImmediateChild) -> Bool)?
    ) -> StorageAnalysisResult {
        var flatScan = collectSynchronously(
            root: root,
            configuration: configuration,
            cancellation: cancellation,
            immediateChildFilter: immediateChildFilter
        )
        deduplicateHardLinks(nodesByPath: &flatScan.nodesByPath)
        return finalize(flatScan)
    }

    static func scanIndependentRootsSynchronously(
        _ roots: [URL],
        configuration: Configuration,
        cancellation: ScanCancellationToken
    ) -> MultiRootAnalysis {
        let flatScans = roots.map {
            collectSynchronously(
                root: $0,
                configuration: configuration,
                cancellation: cancellation,
                immediateChildFilter: nil
            )
        }

        var standaloneScans = flatScans
        for index in standaloneScans.indices {
            deduplicateHardLinks(nodesByPath: &standaloneScans[index].nodesByPath)
        }
        let standaloneResults = standaloneScans.map(finalize)

        var uniqueScans = flatScans
        deduplicateHardLinksAcrossRoots(flatScans: &uniqueScans)
        let uniqueResults = uniqueScans.map(finalize)
        let combinedLogical = uniqueResults.reduce(Int64(0)) {
            saturatedAdd($0, $1.root.logicalSize)
        }
        let combinedAllocated = uniqueResults.reduce(Int64(0)) {
            saturatedAdd($0, $1.root.allocatedSize)
        }

        return MultiRootAnalysis(
            results: standaloneResults,
            combinedUniqueLogicalSize: combinedLogical,
            combinedUniqueAllocatedSize: combinedAllocated
        )
    }

    static func collectSynchronously(
        root: URL,
        configuration: Configuration,
        cancellation: ScanCancellationToken,
        immediateChildFilter: (@Sendable (ImmediateChild) -> Bool)?
    ) -> FlatScan {
        let startedAt = Date()
        let rootPath = root.standardizedFileURL.path
        var rootMetadata = readMetadata(at: rootPath, parentPath: nil, rootDevice: nil)
        if immediateChildFilter != nil {
            rootMetadata.isCountedInParentTotals = false
        }
        let rootDevice = rootMetadata.deviceIdentifier
        var seenHardLinks: [FileIdentity: String] = [:]
        if rootMetadata.hardLinkCount > 1,
           let dev = rootMetadata.deviceIdentifier,
           let ino = rootMetadata.inode {
            seenHardLinks[FileIdentity(device: dev, inode: ino)] = rootPath
        }

        var packagesAggregated = 0
        var descendantEntriesMeasured = 0

        // If the root itself is an application package boundary and package aggregation is enabled:
        if configuration.aggregateApplicationPackages,
           rootPath.hasSuffix(".app"),
           rootMetadata.itemType == .directory {
            let measurement = measurePackageSubtree(
                packageRoot: rootMetadata,
                rootDevice: rootDevice,
                cancellation: cancellation,
                seenHardLinks: &seenHardLinks
            )
            packagesAggregated += 1
            descendantEntriesMeasured += max(measurement.entriesMeasured - 1, 0)

            rootMetadata.aggregateLogicalSize = measurement.logicalSize
            rootMetadata.aggregateAllocatedSize = measurement.allocatedSize
            rootMetadata.accessibility = measurement.accessibility
            rootMetadata.issues = measurement.issues
            rootMetadata.isPackageAggregate = true

            return FlatScan(
                rootPath: rootPath,
                startedAt: startedAt,
                completedAt: Date(),
                rootDeviceIdentifier: rootDevice,
                wasCancelled: cancellation.isCancelled,
                nodesByPath: [rootPath: rootMetadata],
                packagesAggregated: packagesAggregated,
                descendantEntriesMeasured: descendantEntriesMeasured
            )
        }

        var nodesByPath = [rootPath: rootMetadata]
        var pendingDirectories: [String] = []
        if rootMetadata.itemType == .directory {
            pendingDirectories.append(rootPath)
        }
        var pendingIndex = 0

        while pendingIndex < pendingDirectories.count, !cancellation.isCancelled {
            let batchEnd = min(
                pendingIndex + configuration.maxConcurrentDirectoryReads,
                pendingDirectories.count
            )
            let batch = Array(pendingDirectories[pendingIndex..<batchEnd])
            pendingIndex = batchEnd

            for directoryRead in readDirectoryBatch(batch, cancellation: cancellation) {
                if let issue = directoryRead.issue {
                    append(issue, to: directoryRead.path, nodesByPath: &nodesByPath)
                }

                if directoryRead.wasCancelled {
                    markCancelled(directoryRead.path, nodesByPath: &nodesByPath)
                }

                let entryNames = directoryRead.entryNames
                guard !entryNames.isEmpty else { continue }

                let parentPath = directoryRead.path
                var children = [FlatNode?](repeating: nil, count: entryNames.count)

                if entryNames.count >= 8, !cancellation.isCancelled {
                    DispatchQueue.concurrentPerform(iterations: entryNames.count) { index in
                        if !cancellation.isCancelled {
                            let childPath = appending(entryNames[index], to: parentPath)
                            children[index] = readMetadata(
                                at: childPath,
                                parentPath: parentPath,
                                rootDevice: rootDevice
                            )
                        }
                    }
                } else {
                    for index in entryNames.indices {
                        if cancellation.isCancelled { break }
                        let childPath = appending(entryNames[index], to: parentPath)
                        children[index] = readMetadata(
                            at: childPath,
                            parentPath: parentPath,
                            rootDevice: rootDevice
                        )
                    }
                }

                if cancellation.isCancelled {
                    markCancelled(parentPath, nodesByPath: &nodesByPath)
                    break
                }

                for childOpt in children {
                    guard var child = childOpt else { continue }
                    guard nodesByPath[child.path] == nil else { continue }

                    if parentPath == rootPath,
                       let immediateChildFilter,
                       !immediateChildFilter(immediateChild(from: child)) {
                        continue
                    }

                    // Check if child is an application package boundary
                    if configuration.aggregateApplicationPackages,
                       child.name.hasSuffix(".app"),
                       child.itemType == .directory {
                        let measurement = measurePackageSubtree(
                            packageRoot: child,
                            rootDevice: rootDevice,
                            cancellation: cancellation,
                            seenHardLinks: &seenHardLinks
                        )
                        packagesAggregated += 1
                        descendantEntriesMeasured += max(measurement.entriesMeasured - 1, 0)

                        child.aggregateLogicalSize = measurement.logicalSize
                        child.aggregateAllocatedSize = measurement.allocatedSize
                        child.accessibility = measurement.accessibility
                        child.issues = measurement.issues
                        child.isPackageAggregate = true

                        nodesByPath[child.path] = child
                        // Do NOT add to pendingDirectories; internal descendants are not materialized
                        continue
                    }

                    if child.hardLinkCount > 1,
                       let dev = child.deviceIdentifier,
                       let ino = child.inode {
                        let identity = FileIdentity(device: dev, inode: ino)
                        if seenHardLinks[identity] == nil {
                            seenHardLinks[identity] = child.path
                        } else {
                            child.isCountedInParentTotals = false
                        }
                    }

                    nodesByPath[child.path] = child

                    if child.itemType == .directory {
                        pendingDirectories.append(child.path)
                    }
                }
            }
        }

        let wasCancelled = cancellation.isCancelled
        if wasCancelled {
            if pendingIndex < pendingDirectories.count {
                for path in pendingDirectories[pendingIndex...] {
                    markCancelled(path, nodesByPath: &nodesByPath)
                }
            }

            let cancellationIssue = StorageScanIssue(
                path: rootPath,
                kind: .cancelled,
                message: "The storage scan was cancelled before it completed.",
                posixErrorCode: nil
            )
            append(cancellationIssue, to: rootPath, nodesByPath: &nodesByPath)
        }

        return FlatScan(
            rootPath: rootPath,
            startedAt: startedAt,
            completedAt: Date(),
            rootDeviceIdentifier: rootDevice,
            wasCancelled: wasCancelled,
            nodesByPath: nodesByPath,
            packagesAggregated: packagesAggregated,
            descendantEntriesMeasured: descendantEntriesMeasured
        )
    }

    static func measurePackageSubtree(
        packageRoot: FlatNode,
        rootDevice: UInt64?,
        cancellation: ScanCancellationToken,
        seenHardLinks: inout [FileIdentity: String]
    ) -> PackageMeasurement {
        var totalLogical: Int64 = packageRoot.isCountedInParentTotals ? packageRoot.ownLogicalSize : 0
        var totalAllocated: Int64 = packageRoot.isCountedInParentTotals ? packageRoot.ownAllocatedSize : 0
        var issues: [StorageScanIssue] = packageRoot.issues
        var accessibility = packageRoot.accessibility
        var entriesMeasured = 1

        var pendingDirs: [String] = [packageRoot.path]

        while !pendingDirs.isEmpty, !cancellation.isCancelled {
            let currentDir = pendingDirs.removeLast()
            let dirRead = readDirectory(at: currentDir, cancellation: cancellation)

            if let issue = dirRead.issue {
                issues.append(issue)
                if accessibility == .accessible {
                    accessibility = .partiallyAccessible
                }
            }

            if dirRead.wasCancelled {
                if accessibility == .accessible {
                    accessibility = .partiallyAccessible
                }
                break
            }

            for entryName in dirRead.entryNames {
                if cancellation.isCancelled { break }
                let entryPath = appending(entryName, to: currentDir)
                let entryNode = readMetadata(at: entryPath, parentPath: currentDir, rootDevice: rootDevice)
                entriesMeasured += 1

                if !entryNode.issues.isEmpty {
                    issues.append(contentsOf: entryNode.issues)
                    if accessibility == .accessible {
                        accessibility = .partiallyAccessible
                    }
                }

                if entryNode.accessibility != .accessible {
                    if accessibility == .accessible {
                        accessibility = .partiallyAccessible
                    }
                }

                if entryNode.itemType == .volumeBoundary {
                    continue
                }

                if entryNode.itemType == .directory {
                    if entryNode.isCountedInParentTotals {
                        totalLogical = saturatedAdd(totalLogical, entryNode.ownLogicalSize)
                        totalAllocated = saturatedAdd(totalAllocated, entryNode.ownAllocatedSize)
                    }
                    pendingDirs.append(entryNode.path)
                } else if entryNode.itemType == .regularFile {
                    if entryNode.hardLinkCount > 1,
                       let dev = entryNode.deviceIdentifier,
                       let ino = entryNode.inode {
                        let identity = FileIdentity(device: dev, inode: ino)
                        if seenHardLinks[identity] == nil {
                            seenHardLinks[identity] = entryNode.path
                            if entryNode.isCountedInParentTotals {
                                totalLogical = saturatedAdd(totalLogical, entryNode.ownLogicalSize)
                                totalAllocated = saturatedAdd(totalAllocated, entryNode.ownAllocatedSize)
                            }
                        }
                    } else {
                        if entryNode.isCountedInParentTotals {
                            totalLogical = saturatedAdd(totalLogical, entryNode.ownLogicalSize)
                            totalAllocated = saturatedAdd(totalAllocated, entryNode.ownAllocatedSize)
                        }
                    }
                } else {
                    // Symbolic link (not followed) or other special item
                    if entryNode.isCountedInParentTotals {
                        totalLogical = saturatedAdd(totalLogical, entryNode.ownLogicalSize)
                        totalAllocated = saturatedAdd(totalAllocated, entryNode.ownAllocatedSize)
                    }
                }
            }
        }

        if cancellation.isCancelled {
            if accessibility == .accessible {
                accessibility = .partiallyAccessible
            }
            issues.append(StorageScanIssue(
                path: packageRoot.path,
                kind: .cancelled,
                message: "The storage scan was cancelled before it completed.",
                posixErrorCode: nil
            ))
        }

        return PackageMeasurement(
            logicalSize: totalLogical,
            allocatedSize: totalAllocated,
            accessibility: accessibility,
            issues: issues,
            entriesMeasured: entriesMeasured
        )
    }

    static func finalize(_ flatScan: FlatScan) -> StorageAnalysisResult {
        var storageRoot = buildTree(
            rootPath: flatScan.rootPath,
            nodesByPath: flatScan.nodesByPath
        )
        if flatScan.packagesAggregated > 0 {
            var meta = storageRoot.metadata
            meta.attributes["fileTreeScanner.packagesAggregated"] = "\(flatScan.packagesAggregated)"
            meta.attributes["fileTreeScanner.descendantEntriesMeasured"] = "\(flatScan.descendantEntriesMeasured)"
            meta.attributes["fileTreeScanner.descendantNodesAvoided"] = "\(flatScan.descendantEntriesMeasured)"
            storageRoot = StorageNode(
                name: storageRoot.name,
                absolutePath: storageRoot.absolutePath,
                logicalSize: storageRoot.logicalSize,
                allocatedSize: storageRoot.allocatedSize,
                ownLogicalSize: storageRoot.ownLogicalSize,
                ownAllocatedSize: storageRoot.ownAllocatedSize,
                itemType: storageRoot.itemType,
                children: storageRoot.children,
                accessibility: storageRoot.accessibility,
                scanIssues: storageRoot.scanIssues,
                isHidden: storageRoot.isHidden,
                isSymbolicLink: storageRoot.isSymbolicLink,
                isCountedInParentTotals: storageRoot.isCountedInParentTotals,
                metadata: meta
            )
        }
        let issues = flatScan.nodesByPath.values
            .flatMap(\.issues)
            .sorted(by: issueSort)

        return StorageAnalysisResult(
            root: storageRoot,
            startedAt: flatScan.startedAt,
            completedAt: flatScan.completedAt,
            rootDeviceIdentifier: flatScan.rootDeviceIdentifier,
            wasCancelled: flatScan.wasCancelled,
            issues: issues
        )
    }

    static func readDirectoryBatch(
        _ paths: [String],
        cancellation: ScanCancellationToken
    ) -> [DirectoryRead] {
        guard !paths.isEmpty else { return [] }

        let results = DirectoryReadCollector()

        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let result = readDirectory(at: paths[index], cancellation: cancellation)
            results.append(result, at: index)
        }

        return results.orderedResults()
    }

    /// Streams a single directory with POSIX APIs so hidden entries are kept,
    /// symlinks are not resolved, and enumeration errors remain observable.
    static func readDirectory(
        at path: String,
        cancellation: ScanCancellationToken
    ) -> DirectoryRead {
        guard !cancellation.isCancelled else {
            return DirectoryRead(path: path, entryNames: [], issue: nil, wasCancelled: true)
        }

        guard let directory = opendir(path) else {
            let errorCode = Darwin.errno
            return DirectoryRead(
                path: path,
                entryNames: [],
                issue: posixIssue(
                    path: path,
                    errorCode: errorCode,
                    fallbackKind: .directoryEnumerationFailed,
                    operation: "Directory enumeration"
                ),
                wasCancelled: false
            )
        }
        defer { closedir(directory) }

        var entryNames: [String] = []
        while true {
            if cancellation.isCancelled {
                return DirectoryRead(
                    path: path,
                    entryNames: entryNames,
                    issue: nil,
                    wasCancelled: true
                )
            }

            Darwin.errno = 0
            guard let entry = readdir(directory) else {
                let errorCode = Darwin.errno
                let issue: StorageScanIssue?
                if errorCode == 0 {
                    issue = nil
                } else {
                    issue = posixIssue(
                        path: path,
                        errorCode: errorCode,
                        fallbackKind: .directoryEnumerationFailed,
                        operation: "Directory enumeration"
                    )
                }

                return DirectoryRead(
                    path: path,
                    entryNames: entryNames.sorted(),
                    issue: issue,
                    wasCancelled: false
                )
            }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: &nameBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }

            if name != ".", name != ".." {
                entryNames.append(name)
            }
        }
    }

    /// Uses `lstat`, never `stat`, so the target of a symbolic link is never
    /// inspected. POSIX `st_blocks` is reported in 512-byte units on macOS.
    static func readMetadata(
        at path: String,
        parentPath: String?,
        rootDevice: UInt64?
    ) -> FlatNode {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            let errorCode = Darwin.errno
            return FlatNode(
                name: displayName(for: path),
                path: path,
                parentPath: parentPath,
                itemType: .unknown,
                ownLogicalSize: 0,
                ownAllocatedSize: 0,
                deviceIdentifier: nil,
                inode: nil,
                hardLinkCount: 0,
                isHidden: pathComponentIsHidden(path),
                isSymbolicLink: false,
                isCountedInParentTotals: false,
                accessibility: .inaccessible,
                issues: [
                    posixIssue(
                        path: path,
                        errorCode: errorCode,
                        fallbackKind: .metadataUnavailable,
                        operation: "Metadata read"
                    )
                ]
            )
        }

        let deviceIdentifier = UInt64(metadata.st_dev)
        let inode = UInt64(metadata.st_ino)
        let mode = metadata.st_mode & mode_t(S_IFMT)
        let isSymbolicLink = mode == mode_t(S_IFLNK)
        let regularType: StorageItemType
        switch mode {
        case mode_t(S_IFDIR):
            regularType = .directory
        case mode_t(S_IFREG):
            regularType = .regularFile
        case mode_t(S_IFLNK):
            regularType = .symbolicLink
        default:
            regularType = .other
        }

        let logicalSize = max(Int64(metadata.st_size), 0)
        let allocatedSize = saturatedMultiply(max(Int64(metadata.st_blocks), 0), by: 512)
        let hiddenByFlag = (UInt32(metadata.st_flags) & UInt32(UF_HIDDEN)) != 0
        let isHidden = pathComponentIsHidden(path) || hiddenByFlag

        if let rootDevice, deviceIdentifier != rootDevice {
            return FlatNode(
                name: displayName(for: path),
                path: path,
                parentPath: parentPath,
                itemType: .volumeBoundary,
                ownLogicalSize: logicalSize,
                ownAllocatedSize: allocatedSize,
                deviceIdentifier: deviceIdentifier,
                inode: inode,
                hardLinkCount: UInt64(metadata.st_nlink),
                isHidden: isHidden,
                isSymbolicLink: isSymbolicLink,
                isCountedInParentTotals: false,
                accessibility: .skippedDifferentVolume,
                issues: [
                    StorageScanIssue(
                        path: path,
                        kind: .differentVolume,
                        message: "Traversal stopped because this item is on a different mounted filesystem.",
                        posixErrorCode: nil
                    )
                ]
            )
        }

        return FlatNode(
            name: displayName(for: path),
            path: path,
            parentPath: parentPath,
            itemType: regularType,
            ownLogicalSize: logicalSize,
            ownAllocatedSize: allocatedSize,
            deviceIdentifier: deviceIdentifier,
            inode: inode,
            hardLinkCount: UInt64(metadata.st_nlink),
            isHidden: isHidden,
            isSymbolicLink: isSymbolicLink,
            isCountedInParentTotals: true,
            accessibility: .accessible,
            issues: []
        )
    }

    static func immediateChild(from node: FlatNode) -> ImmediateChild {
        ImmediateChild(
            name: node.name,
            absolutePath: node.path,
            itemType: node.itemType,
            accessibility: node.accessibility,
            isHidden: node.isHidden,
            isSymbolicLink: node.isSymbolicLink
        )
    }

    static func deduplicateHardLinks(nodesByPath: inout [String: FlatNode]) {
        var firstPathByIdentity: [FileIdentity: String] = [:]

        for path in nodesByPath.keys.sorted() {
            guard var node = nodesByPath[path],
                  node.itemType == .regularFile,
                  node.hardLinkCount > 1,
                  let device = node.deviceIdentifier,
                  let inode = node.inode else {
                continue
            }

            let identity = FileIdentity(device: device, inode: inode)
            if firstPathByIdentity[identity] == nil {
                firstPathByIdentity[identity] = path
            } else {
                node.isCountedInParentTotals = false
                nodesByPath[path] = node
            }
        }
    }

    static func deduplicateHardLinksAcrossRoots(flatScans: inout [FlatScan]) {
        var firstLocationByIdentity: [FileIdentity: (rootIndex: Int, path: String)] = [:]

        for rootIndex in flatScans.indices {
            for path in flatScans[rootIndex].nodesByPath.keys.sorted() {
                guard var node = flatScans[rootIndex].nodesByPath[path],
                      node.itemType == .regularFile,
                      node.hardLinkCount > 1,
                      let device = node.deviceIdentifier,
                      let inode = node.inode else {
                    continue
                }

                let identity = FileIdentity(device: device, inode: inode)
                if firstLocationByIdentity[identity] == nil {
                    firstLocationByIdentity[identity] = (rootIndex, path)
                } else {
                    node.isCountedInParentTotals = false
                    flatScans[rootIndex].nodesByPath[path] = node
                }
            }
        }
    }

    static func buildTree(
        rootPath: String,
        nodesByPath: [String: FlatNode]
    ) -> StorageNode {
        let paths = nodesByPath.keys.sorted {
            let leftDepth = pathDepth($0)
            let rightDepth = pathDepth($1)
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0 < $1
        }

        var childrenByParent: [String: [StorageNode]] = [:]
        var root: StorageNode?

        for path in paths {
            guard let flatNode = nodesByPath[path] else { continue }
            let children = (childrenByParent[path] ?? []).sorted { $0.absolutePath < $1.absolutePath }

            var logicalSize: Int64
            var allocatedSize: Int64
            if flatNode.isPackageAggregate {
                logicalSize = flatNode.aggregateLogicalSize ?? flatNode.ownLogicalSize
                allocatedSize = flatNode.aggregateAllocatedSize ?? flatNode.ownAllocatedSize
            } else {
                logicalSize = flatNode.isCountedInParentTotals ? flatNode.ownLogicalSize : 0
                allocatedSize = flatNode.isCountedInParentTotals ? flatNode.ownAllocatedSize : 0
                for child in children {
                    logicalSize = saturatedAdd(logicalSize, child.logicalSize)
                    allocatedSize = saturatedAdd(allocatedSize, child.allocatedSize)
                }
            }

            var accessibility = flatNode.accessibility
            if accessibility == .accessible,
               children.contains(where: { $0.accessibility != .accessible }) {
                accessibility = .partiallyAccessible
            }

            let node = StorageNode(
                name: flatNode.name,
                absolutePath: flatNode.path,
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                ownLogicalSize: flatNode.ownLogicalSize,
                ownAllocatedSize: flatNode.ownAllocatedSize,
                itemType: flatNode.itemType,
                children: children,
                accessibility: accessibility,
                scanIssues: flatNode.issues.sorted(by: issueSort),
                isHidden: flatNode.isHidden,
                isSymbolicLink: flatNode.isSymbolicLink,
                isCountedInParentTotals: flatNode.isCountedInParentTotals,
                metadata: StorageAnalysisMetadata()
            )

            if path == rootPath {
                root = node
            } else if let parentPath = flatNode.parentPath {
                childrenByParent[parentPath, default: []].append(node)
            }
        }

        if let root { return root }

        // `readMetadata` always creates a root. This defensive fallback keeps
        // the result representable if future filtering changes that invariant.
        return StorageNode(
            name: displayName(for: rootPath),
            absolutePath: rootPath,
            logicalSize: 0,
            allocatedSize: 0,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .unknown,
            children: [],
            accessibility: .inaccessible,
            scanIssues: [],
            isHidden: pathComponentIsHidden(rootPath),
            isSymbolicLink: false,
            isCountedInParentTotals: false,
            metadata: StorageAnalysisMetadata()
        )
    }

    static func append(
        _ issue: StorageScanIssue,
        to path: String,
        nodesByPath: inout [String: FlatNode]
    ) {
        guard var node = nodesByPath[path] else { return }
        if !node.issues.contains(issue) {
            node.issues.append(issue)
        }
        if node.accessibility == .accessible {
            node.accessibility = issue.kind == .permissionDenied ? .inaccessible : .partiallyAccessible
        }
        nodesByPath[path] = node
    }

    static func markCancelled(
        _ path: String,
        nodesByPath: inout [String: FlatNode]
    ) {
        guard var node = nodesByPath[path] else { return }
        let issue = StorageScanIssue(
            path: path,
            kind: .cancelled,
            message: "This location was not fully scanned because the operation was cancelled.",
            posixErrorCode: nil
        )
        if !node.issues.contains(issue) {
            node.issues.append(issue)
        }
        node.accessibility = .cancelled
        nodesByPath[path] = node
    }

    static func posixIssue(
        path: String,
        errorCode: Int32,
        fallbackKind: StorageScanIssueKind,
        operation: String
    ) -> StorageScanIssue {
        let kind: StorageScanIssueKind
        if errorCode == EACCES || errorCode == EPERM {
            kind = .permissionDenied
        } else {
            kind = fallbackKind
        }

        let errorDescription = String(cString: strerror(errorCode))
        return StorageScanIssue(
            path: path,
            kind: kind,
            message: "\(operation) failed: \(errorDescription)",
            posixErrorCode: errorCode
        )
    }

    static func displayName(for path: String) -> String {
        if path == "/" { return "/" }
        return String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(path))
    }

    static func pathComponentIsHidden(_ path: String) -> Bool {
        guard path != "/" else { return false }
        return displayName(for: path).hasPrefix(".")
    }

    static func appending(_ component: String, to path: String) -> String {
        path == "/" ? "/\(component)" : "\(path)/\(component)"
    }

    static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    static func saturatedAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : result
    }

    static func saturatedMultiply(_ value: Int64, by multiplier: Int64) -> Int64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? Int64.max : result
    }

    static func issueSort(_ left: StorageScanIssue, _ right: StorageScanIssue) -> Bool {
        if left.path != right.path { return left.path < right.path }
        if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
        return left.message < right.message
    }
}

private final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
