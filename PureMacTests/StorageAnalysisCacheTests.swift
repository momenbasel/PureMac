import XCTest
@testable import PureMac

final class StorageAnalysisCacheTests: XCTestCase {

    private func makeTestNode(
        name: String,
        path: String,
        allocatedSize: Int64,
        logicalSize: Int64,
        itemType: StorageItemType = .directory,
        children: [StorageNode] = [],
        issues: [StorageScanIssue] = []
    ) -> StorageNode {
        StorageNode(
            name: name,
            absolutePath: path,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            ownLogicalSize: itemType == .directory ? 0 : logicalSize,
            ownAllocatedSize: itemType == .directory ? 0 : allocatedSize,
            itemType: itemType,
            children: children,
            accessibility: issues.isEmpty ? .accessible : .inaccessible,
            scanIssues: issues,
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )
    }

    func testExactPathCacheHit() {
        let cache = StorageAnalysisCache()
        let rootNode = makeTestNode(name: "Applications", path: "/Applications", allocatedSize: 1000, logicalSize: 1000)
        let analysisResult = StorageAnalysisResult(
            root: rootNode,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )

        cache.store(analysisResult, isFullSubtree: true)

        let cached = cache.get(path: "/Applications")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.root.allocatedSize, 1000)
        let metrics = cache.metrics
        XCTAssertEqual(metrics.cacheHitCount, 1)
        XCTAssertEqual(metrics.cacheMissCount, 0)
    }

    func testFirmlinkPathNormalizationReusesCache() {
        let cache = StorageAnalysisCache()
        let rootNode = makeTestNode(name: "Applications", path: "/Applications", allocatedSize: 5000, logicalSize: 5000)
        let analysisResult = StorageAnalysisResult(
            root: rootNode,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )

        cache.store(analysisResult, isFullSubtree: true)

        // Querying through the firmlink path /System/Volumes/Data/Applications
        let cached = cache.get(path: "/System/Volumes/Data/Applications")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.root.allocatedSize, 5000)
        let metrics = cache.metrics
        XCTAssertEqual(metrics.cacheHitCount, 1)
        XCTAssertEqual(metrics.avoidedTraversalsCount, 1)
    }

    func testSubtreeExtractionFromFullParentScan() {
        let cache = StorageAnalysisCache()
        let dockerChild = makeTestNode(
            name: "com.docker.docker",
            path: "/Users/test/Library/Containers/com.docker.docker",
            allocatedSize: 2048,
            logicalSize: 2048,
            issues: [
                StorageScanIssue(
                    path: "/Users/test/Library/Containers/com.docker.docker/data.db",
                    kind: .permissionDenied,
                    message: "Permission denied",
                    posixErrorCode: 13
                )
            ]
        )
        let parentNode = makeTestNode(
            name: "Containers",
            path: "/Users/test/Library/Containers",
            allocatedSize: 10000,
            logicalSize: 10000,
            children: [dockerChild]
        )
        let parentResult = StorageAnalysisResult(
            root: parentNode,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: dockerChild.scanIssues
        )

        cache.store(parentResult, isFullSubtree: true)

        // Subtree query for com.docker.docker
        let subtree = cache.get(path: "/Users/test/Library/Containers/com.docker.docker")
        XCTAssertNotNil(subtree)
        XCTAssertEqual(subtree?.root.name, "com.docker.docker")
        XCTAssertEqual(subtree?.root.allocatedSize, 2048)
        XCTAssertEqual(subtree?.issues.count, 1)
        XCTAssertEqual(subtree?.issues.first?.kind, .permissionDenied)
        let metrics = cache.metrics
        XCTAssertEqual(metrics.reusedSubtreeCount, 1)
        XCTAssertEqual(metrics.avoidedTraversalsCount, 1)
    }

    func testDeepNestedSubtreeExtraction() {
        let cache = StorageAnalysisCache()
        let deepFile = makeTestNode(
            name: "file.txt",
            path: "/Users/test/Library/Application Support/Docker Desktop/vms/0/data/file.txt",
            allocatedSize: 512,
            logicalSize: 512,
            itemType: .regularFile
        )
        let vmsFolder = makeTestNode(
            name: "vms",
            path: "/Users/test/Library/Application Support/Docker Desktop/vms",
            allocatedSize: 512,
            logicalSize: 512,
            children: [deepFile]
        )
        let dockerAppSupport = makeTestNode(
            name: "Docker Desktop",
            path: "/Users/test/Library/Application Support/Docker Desktop",
            allocatedSize: 512,
            logicalSize: 512,
            children: [vmsFolder]
        )
        let appSupport = makeTestNode(
            name: "Application Support",
            path: "/Users/test/Library/Application Support",
            allocatedSize: 5000,
            logicalSize: 5000,
            children: [dockerAppSupport]
        )

        let appSupportResult = StorageAnalysisResult(
            root: appSupport,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )
        cache.store(appSupportResult, isFullSubtree: true)

        let extracted = cache.get(path: "/Users/test/Library/Application Support/Docker Desktop")
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.root.name, "Docker Desktop")
        XCTAssertEqual(extracted?.root.allocatedSize, 512)
        XCTAssertEqual(extracted?.root.children.count, 1)
        XCTAssertEqual(extracted?.root.children.first?.name, "vms")
    }

    func testCacheMissForUnrelatedPath() {
        let cache = StorageAnalysisCache()
        let rootNode = makeTestNode(name: "Containers", path: "/Users/test/Library/Containers", allocatedSize: 1000, logicalSize: 1000)
        let analysisResult = StorageAnalysisResult(
            root: rootNode,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )
        cache.store(analysisResult, isFullSubtree: true)

        let missing = cache.get(path: "/Users/test/Library/Application Support")
        XCTAssertNil(missing)
        let metrics = cache.metrics
        XCTAssertEqual(metrics.cacheMissCount, 1)
    }

    func testConcurrentScanOrCoalescePerformsSinglePhysicalTraversal() async throws {
        let cache = StorageAnalysisCache()
        var physicalTraversals = 0
        let lock = NSLock()

        let scanClosure: @Sendable () async throws -> StorageAnalysisResult = {
            lock.lock()
            physicalTraversals += 1
            lock.unlock()
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms simulated scan
            let node = StorageNode(
                name: "shared",
                absolutePath: "/test/shared",
                logicalSize: 4096,
                allocatedSize: 4096,
                ownLogicalSize: 4096,
                ownAllocatedSize: 4096,
                itemType: .directory,
                children: [],
                accessibility: .accessible,
                scanIssues: [],
                isHidden: false,
                isSymbolicLink: false,
                isCountedInParentTotals: true,
                metadata: StorageAnalysisMetadata()
            )
            return StorageAnalysisResult(
                root: node,
                startedAt: Date(),
                completedAt: Date(),
                rootDeviceIdentifier: 1,
                wasCancelled: false,
                issues: []
            )
        }

        // Launch 4 concurrent requests for the exact same path
        async let r1 = cache.scanOrCoalesce(path: "/test/shared", performScan: scanClosure)
        async let r2 = cache.scanOrCoalesce(path: "/test/shared", performScan: scanClosure)
        async let r3 = cache.scanOrCoalesce(path: "/test/shared", performScan: scanClosure)
        async let r4 = cache.scanOrCoalesce(path: "/test/shared", performScan: scanClosure)

        let results = try await [r1, r2, r3, r4]

        XCTAssertEqual(results.count, 4)
        for res in results {
            XCTAssertEqual(res.root.allocatedSize, 4096)
        }
        XCTAssertEqual(physicalTraversals, 1)
        let metrics = cache.metrics
        XCTAssertEqual(metrics.physicalTraversalsCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.avoidedTraversalsCount, 3)
    }

    func testCancelledScanDoesNotPoisonCache() async throws {
        let cache = StorageAnalysisCache()

        let cancelledScan: @Sendable () async throws -> StorageAnalysisResult = {
            let node = StorageNode(
                name: "cancelled",
                absolutePath: "/test/cancelled",
                logicalSize: 0,
                allocatedSize: 0,
                ownLogicalSize: 0,
                ownAllocatedSize: 0,
                itemType: .directory,
                children: [],
                accessibility: .inaccessible,
                scanIssues: [],
                isHidden: false,
                isSymbolicLink: false,
                isCountedInParentTotals: true,
                metadata: StorageAnalysisMetadata()
            )
            return StorageAnalysisResult(
                root: node,
                startedAt: Date(),
                completedAt: Date(),
                rootDeviceIdentifier: 1,
                wasCancelled: true,
                issues: []
            )
        }

        _ = try await cache.scanOrCoalesce(path: "/test/cancelled", performScan: cancelledScan)

        // Cache must not have stored the cancelled scan
        let lookup = cache.get(path: "/test/cancelled")
        XCTAssertNil(lookup)
    }

    func testPreservesByteCountsAndInvariants() {
        let cache = StorageAnalysisCache()
        let child1 = makeTestNode(name: "A", path: "/opt/homebrew/A", allocatedSize: 4096, logicalSize: 3000)
        let child2 = makeTestNode(name: "B", path: "/opt/homebrew/B", allocatedSize: 8192, logicalSize: 7000)
        let parent = makeTestNode(
            name: "homebrew",
            path: "/opt/homebrew",
            allocatedSize: 12288,
            logicalSize: 10000,
            children: [child1, child2]
        )

        let parentResult = StorageAnalysisResult(
            root: parent,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )
        cache.store(parentResult, isFullSubtree: true)

        let extractedA = cache.get(path: "/opt/homebrew/A")
        XCTAssertNotNil(extractedA)
        XCTAssertEqual(extractedA?.root.allocatedSize, 4096)
        XCTAssertEqual(extractedA?.root.logicalSize, 3000)

        let extractedB = cache.get(path: "/opt/homebrew/B")
        XCTAssertNotNil(extractedB)
        XCTAssertEqual(extractedB?.root.allocatedSize, 8192)
        XCTAssertEqual(extractedB?.root.logicalSize, 7000)
    }

    func testRealTraversalPipelineReusesSubtreesAndReportsMetrics() async throws {
        let cache = StorageAnalysisCache()
        let scanner = FileTreeScanner(cache: cache)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let containersDir = tempDir.appendingPathComponent("Containers")
        let dockerContainerDir = containersDir.appendingPathComponent("com.docker.docker")
        let appSupportDir = tempDir.appendingPathComponent("Application Support")
        let dockerAppSupportDir = appSupportDir.appendingPathComponent("Docker Desktop")

        try FileManager.default.createDirectory(at: dockerContainerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dockerAppSupportDir, withIntermediateDirectories: true)
        try "test data 1".write(to: dockerContainerDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        try "test data 2".write(to: dockerAppSupportDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Stage 1: ContainersAnalyzer scans ~/Library/Containers
        let containersAnalyzer = ContainersAnalyzer(containersURL: containersDir, scanner: scanner, cache: cache)
        let containersResult = await containersAnalyzer.analyze()
        XCTAssertGreaterThan(containersResult.root.allocatedSize, 0)

        // 2. Stage 2: ApplicationSupportAnalyzer scans ~/Library/Application Support
        let appSupportAnalyzer = ApplicationSupportAnalyzer(applicationSupportURL: appSupportDir, scanner: scanner, cache: cache)
        let appSupportResult = await appSupportAnalyzer.analyze()
        XCTAssertGreaterThan(appSupportResult.root.allocatedSize, 0)

        // 3. Stage 3: DockerStorageAnalyzer inspects its host footprint roots
        let dockerAnalyzer = DockerStorageAnalyzer(
            hostStorageRoots: [dockerContainerDir, dockerAppSupportDir],
            scanner: scanner,
            cache: cache,
            executableLocator: { nil }
        )
        let dockerReport = await dockerAnalyzer.analyze()
        XCTAssertEqual(dockerReport.hostFootprint.locations.count, 2)

        // 4. Verify that DockerStorageAnalyzer reused both subtrees from cache with zero disk scans
        let metrics = cache.metrics
        XCTAssertEqual(metrics.physicalTraversalsCount, 2) // only Containers & AppSupport were physically traversed
        XCTAssertGreaterThanOrEqual(metrics.cacheHitCount, 2)
        XCTAssertGreaterThanOrEqual(metrics.reusedSubtreeCount, 2)
        XCTAssertGreaterThanOrEqual(metrics.avoidedTraversalsCount, 2)
    }
}
