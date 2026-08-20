import Foundation

/// Performance metrics for run-scoped storage scan caching and subtree reuse.
struct StorageAnalysisCacheMetrics: Hashable, Codable, Sendable {
    var physicalTraversalsCount: Int = 0
    var cacheHitCount: Int = 0
    var cacheMissCount: Int = 0
    var reusedSubtreeCount: Int = 0
    var avoidedTraversalsCount: Int = 0
}

/// Run-scoped, thread-safe cache for filesystem scan results with in-flight task coalescing.
///
/// Ensures that any canonical filesystem subtree is physically traversed at most
/// once per analysis run. When an analyzer requests a scan for a path that is
/// identical to, currently in flight, or contained within an already-scanned full
/// recursive tree, the existing or in-flight subtree is reused with zero duplicate I/O.
final class StorageAnalysisCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resultsByNormalizedPath: [String: StorageAnalysisResult] = [:]
    private var fullSubtreeRootPaths: Set<String> = []
    private var inFlightTasks: [String: Task<StorageAnalysisResult, Error>] = [:]

    private var _metrics = StorageAnalysisCacheMetrics()

    var metrics: StorageAnalysisCacheMetrics {
        lock.withLock { _metrics }
    }

    init() {}

    /// Retrieves an existing result if the exact normalized path or a containing
    /// full-subtree parent has already been scanned with compatible semantics.
    func get(path: String) -> StorageAnalysisResult? {
        let normPath = StoragePathNormalizer.normalize(path)
        return lock.withLock {
            getSynchronouslyLocked(normPath: normPath)
        }
    }

    private func getSynchronouslyLocked(normPath: String) -> StorageAnalysisResult? {
        // 1. Exact match
        if let exact = resultsByNormalizedPath[normPath] {
            _metrics.cacheHitCount += 1
            _metrics.avoidedTraversalsCount += 1
            return exact
        }

        // 2. Subtree match inside an existing full recursive scan
        for parentPath in fullSubtreeRootPaths {
            guard normPath == parentPath || normPath.hasPrefix(parentPath + "/") else {
                continue
            }

            guard let parentResult = resultsByNormalizedPath[parentPath] else {
                continue
            }

            if let subtreeNode = Self.findSubtreeNode(in: parentResult.root, targetNormalizedPath: normPath) {
                let subtreeResult = Self.makeSubtreeResult(from: subtreeNode, parentResult: parentResult)
                resultsByNormalizedPath[normPath] = subtreeResult
                _metrics.cacheHitCount += 1
                _metrics.reusedSubtreeCount += 1
                _metrics.avoidedTraversalsCount += 1
                return subtreeResult
            }
        }

        _metrics.cacheMissCount += 1
        return nil
    }

    /// Performs an asynchronous scan or coalesces with an already running scan
    /// for the same canonical root, caching the result on completion.
    func scanOrCoalesce(
        path: String,
        performScan: @Sendable @escaping () async throws -> StorageAnalysisResult
    ) async throws -> StorageAnalysisResult {
        let normPath = StoragePathNormalizer.normalize(path)

        enum InFlightAction {
            case returnCached(StorageAnalysisResult)
            case awaitExisting(Task<StorageAnalysisResult, Error>)
            case awaitCreated(Task<StorageAnalysisResult, Error>)
        }

        let action: InFlightAction = lock.withLock {
            if let cached = getSynchronouslyLocked(normPath: normPath) {
                return .returnCached(cached)
            }
            if let existing = inFlightTasks[normPath] {
                _metrics.cacheHitCount += 1
                _metrics.avoidedTraversalsCount += 1
                return .awaitExisting(existing)
            }

            let task = Task<StorageAnalysisResult, Error> {
                try await performScan()
            }
            inFlightTasks[normPath] = task
            _metrics.physicalTraversalsCount += 1
            return .awaitCreated(task)
        }

        switch action {
        case let .returnCached(result):
            return result
        case let .awaitExisting(task):
            return try await task.value
        case let .awaitCreated(task):
            do {
                let result = try await task.value
                lock.withLock {
                    inFlightTasks.removeValue(forKey: normPath)
                    if !result.wasCancelled {
                        resultsByNormalizedPath[normPath] = result
                        fullSubtreeRootPaths.insert(normPath)
                    }
                }
                return result
            } catch {
                lock.withLock {
                    inFlightTasks.removeValue(forKey: normPath)
                }
                throw error
            }
        }
    }

    /// Stores a scan result in the run-scoped cache.
    func store(_ result: StorageAnalysisResult, isFullSubtree: Bool) {
        guard !result.wasCancelled else { return }
        let normPath = StoragePathNormalizer.normalize(result.root.absolutePath)

        lock.withLock {
            resultsByNormalizedPath[normPath] = result
            if isFullSubtree {
                fullSubtreeRootPaths.insert(normPath)
            }
        }
    }

    /// Recursively locates a descendant node matching the target normalized path.
    static func findSubtreeNode(in root: StorageNode, targetNormalizedPath: String) -> StorageNode? {
        let rootNorm = StoragePathNormalizer.normalize(root.absolutePath)
        if rootNorm == targetNormalizedPath {
            return root
        }

        guard targetNormalizedPath.hasPrefix(rootNorm + "/") || rootNorm == "/" else {
            return nil
        }

        for child in root.children {
            let childNorm = StoragePathNormalizer.normalize(child.absolutePath)
            if childNorm == targetNormalizedPath {
                return child
            }
            if targetNormalizedPath.hasPrefix(childNorm + "/") {
                if let match = findSubtreeNode(in: child, targetNormalizedPath: targetNormalizedPath) {
                    return match
                }
            }
        }

        return nil
    }

    /// Builds a standalone StorageAnalysisResult representing the extracted subtree.
    static func makeSubtreeResult(
        from node: StorageNode,
        parentResult: StorageAnalysisResult
    ) -> StorageAnalysisResult {
        let nodeNorm = StoragePathNormalizer.normalize(node.absolutePath)
        let relevantIssues = parentResult.issues.filter { issue in
            let issueNorm = StoragePathNormalizer.normalize(issue.path)
            return issueNorm == nodeNorm || issueNorm.hasPrefix(nodeNorm + "/")
        }

        return StorageAnalysisResult(
            root: node,
            startedAt: parentResult.startedAt,
            completedAt: parentResult.completedAt,
            rootDeviceIdentifier: parentResult.rootDeviceIdentifier,
            wasCancelled: parentResult.wasCancelled,
            issues: relevantIssues
        )
    }
}
