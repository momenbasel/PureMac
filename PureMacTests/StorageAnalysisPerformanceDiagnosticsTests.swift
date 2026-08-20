import XCTest
@testable import PureMac

final class StorageAnalysisPerformanceDiagnosticsTests: XCTestCase {
    func testStorageScanMetricsComputation() {
        let childFile1 = StorageNode(
            name: "file1.txt",
            absolutePath: "/test/file1.txt",
            logicalSize: 1024,
            allocatedSize: 4096,
            ownLogicalSize: 1024,
            ownAllocatedSize: 4096,
            itemType: .regularFile,
            children: [],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let childFile2 = StorageNode(
            name: "file2.txt",
            absolutePath: "/test/sub/file2.txt",
            logicalSize: 2048,
            allocatedSize: 8192,
            ownLogicalSize: 2048,
            ownAllocatedSize: 8192,
            itemType: .regularFile,
            children: [],
            accessibility: .inaccessible,
            scanIssues: [StorageScanIssue(path: "/test/sub/file2.txt", kind: .permissionDenied, message: "Denied", posixErrorCode: nil)],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let subDir = StorageNode(
            name: "sub",
            absolutePath: "/test/sub",
            logicalSize: 2048,
            allocatedSize: 8192,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .directory,
            children: [childFile2],
            accessibility: .partiallyAccessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let rootNode = StorageNode(
            name: "test",
            absolutePath: "/test",
            logicalSize: 3072,
            allocatedSize: 12288,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .directory,
            children: [childFile1, subDir],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let metrics = StorageScanMetrics.compute(from: rootNode)

        XCTAssertEqual(metrics.totalEntries, 4)
        XCTAssertEqual(metrics.directoryCount, 2)
        XCTAssertEqual(metrics.fileCount, 2)
        XCTAssertEqual(metrics.allocatedBytes, 12288)
        XCTAssertEqual(metrics.logicalBytes, 3072)
        XCTAssertEqual(metrics.permissionFailureCount, 1)
        XCTAssertEqual(metrics.boundarySkipCount, 0)
    }

    func testPerformanceReportFormatting() {
        let record1 = StagePerformanceRecord(
            stageName: "Applications",
            durationSeconds: 2.80,
            metrics: StorageScanMetrics(
                totalEntries: 61210,
                directoryCount: 5000,
                fileCount: 56210,
                otherCount: 0,
                allocatedBytes: 40_000_000_000,
                logicalBytes: 38_000_000_000,
                permissionFailureCount: 0,
                boundarySkipCount: 0
            ),
            customNote: nil
        )

        let record2 = StagePerformanceRecord(
            stageName: "Coverage Expansion",
            durationSeconds: 5.80,
            metrics: nil,
            customNote: "185 discovered, 108 roots scanned"
        )

        let obs = DuplicateScanObservation(
            path: "/Applications",
            primaryScanner: "ApplicationsStorageAnalyzer",
            secondaryScanner: "CoverageExpansionAnalyzer",
            relationship: "Excluded canonical root"
        )

        let report = StorageAnalysisPerformanceReport(
            totalDurationSeconds: 8.60,
            stageRecords: [record1, record2],
            duplicateObservations: [obs]
        )

        let debugString = report.formattedDebugString()

        XCTAssertTrue(debugString.contains("PureMac Storage Analysis Performance"))
        XCTAssertTrue(debugString.contains("8.60s"))
        XCTAssertTrue(debugString.contains("Applications"))
        XCTAssertTrue(debugString.contains("Coverage Expansion"))
        XCTAssertTrue(debugString.contains("Potential Duplicate / Overlapping Recursive Coverage"))
        XCTAssertTrue(debugString.contains("/Applications"))
    }

    func testDuplicateScanAnalysisSurfacesDockerAndFirmlinks() {
        let node = StorageNode(
            name: "com.docker.docker",
            absolutePath: "/Users/test/Library/Containers/com.docker.docker",
            logicalSize: 100,
            allocatedSize: 100,
            ownLogicalSize: 100,
            ownAllocatedSize: 100,
            itemType: .directory,
            children: [],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let dockerResult = StorageAnalysisResult(
            root: node,
            startedAt: Date(),
            completedAt: Date(),
            rootDeviceIdentifier: 1,
            wasCancelled: false,
            issues: []
        )

        let dockerReport = DockerStorageReport(
            hostFootprint: DockerHostFootprint(locations: [dockerResult], logicalSize: 100, allocatedSize: 100),
            virtualDisks: [],
            runtimeStatus: .notInstalled,
            runtimeAccounting: nil,
            dockerExecutablePath: nil,
            runtimeContext: DockerRuntimeContext(name: "test", sanitizedEndpoint: "unix:///test", location: .local),
            hostRuntimeRelationship: .localRuntimeMayExplainHostFootprint,
            accountingRelationship: .runtimeBreakdownIsNonAdditiveToHostFootprint,
            wasCancelled: false,
            issues: []
        )

        let results = StorageAnalyzerResults(dockerStorage: dockerReport)

        let duplicates = StorageAnalysisPerformanceDiagnostics.analyzeDuplicates(
            results: results,
            expansionReport: nil
        )

        XCTAssertTrue(duplicates.contains { $0.path.contains("com.docker.docker") })
        XCTAssertTrue(duplicates.contains { $0.path.contains("/Applications") })
    }

    func testFindHeaviestSubtrees() {
        var files: [StorageNode] = []
        for i in 0..<150 {
            files.append(StorageNode(
                name: "file\(i).js",
                absolutePath: "/Users/test/Projects/my_app/node_modules/pkg/file\(i).js",
                logicalSize: 100,
                allocatedSize: 100,
                ownLogicalSize: 100,
                ownAllocatedSize: 100,
                itemType: .regularFile,
                children: [],
                accessibility: .accessible,
                scanIssues: [],
                isHidden: false,
                isSymbolicLink: false,
                isCountedInParentTotals: true,
                metadata: StorageAnalysisMetadata()
            ))
        }

        let nodeModules = StorageNode(
            name: "node_modules",
            absolutePath: "/Users/test/Projects/my_app/node_modules",
            logicalSize: 15000,
            allocatedSize: 15000,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .directory,
            children: files,
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let root = StorageNode(
            name: "Projects",
            absolutePath: "/Users/test/Projects",
            logicalSize: 15000,
            allocatedSize: 15000,
            ownLogicalSize: 0,
            ownAllocatedSize: 0,
            itemType: .directory,
            children: [nodeModules],
            accessibility: .accessible,
            scanIssues: [],
            isHidden: false,
            isSymbolicLink: false,
            isCountedInParentTotals: true,
            metadata: StorageAnalysisMetadata()
        )

        let heaviest = StorageAnalysisPerformanceDiagnostics.findHeaviestSubtrees(from: [root], limit: 5)
        XCTAssertEqual(heaviest.count, 1)
        XCTAssertEqual(heaviest.first?.path, "/Users/test/Projects/my_app/node_modules")
        XCTAssertEqual(heaviest.first?.totalEntries, 151)
    }

    func testFormattedDebugStringWithHeaviestSubtreesAndCacheMetrics() {
        let subtree1 = SlowestSubtreeRecord(
            path: "/Applications/Xcode.app",
            totalEntries: 450_000,
            directoryCount: 60_000,
            fileCount: 390_000,
            allocatedBytes: 40_000_000_000,
            isPackageOrApp: true
        )
        let subtree2 = SlowestSubtreeRecord(
            path: "/Users/test/node_modules",
            totalEntries: 120_000,
            directoryCount: 15_000,
            fileCount: 105_000,
            allocatedBytes: 2_000_000_000,
            isPackageOrApp: false
        )

        let stageRecord = StagePerformanceRecord(
            stageName: "Applications",
            durationSeconds: 317.20,
            metrics: StorageScanMetrics(
                totalEntries: 457_636,
                directoryCount: 64_715,
                fileCount: 379_567,
                otherCount: 0,
                allocatedBytes: 43_000_000_000,
                logicalBytes: 40_000_000_000,
                permissionFailureCount: 0,
                boundarySkipCount: 0
            ),
            customNote: nil
        )

        let cacheMetrics = StorageAnalysisCacheMetrics(
            physicalTraversalsCount: 137,
            cacheHitCount: 14,
            cacheMissCount: 148,
            reusedSubtreeCount: 13,
            avoidedTraversalsCount: 14
        )

        let report = StorageAnalysisPerformanceReport(
            totalDurationSeconds: 386.26,
            stageRecords: [stageRecord],
            duplicateObservations: [],
            cacheMetrics: cacheMetrics,
            heaviestSubtrees: [subtree1, subtree2]
        )

        let debugString = report.formattedDebugString()

        XCTAssertTrue(debugString.contains("386.26s"))
        XCTAssertTrue(debugString.contains("Applications"))
        XCTAssertTrue(debugString.contains("Scan Cache & Subtree Reuse"))
        XCTAssertTrue(debugString.contains("Physical Traversals:    137"))
        XCTAssertTrue(debugString.contains("Top High-Density Subtrees & Application Bundles"))
        XCTAssertTrue(debugString.contains("[App Bundle]"))
        XCTAssertTrue(debugString.contains("[Directory]"))
        XCTAssertTrue(debugString.contains("/Applications/Xcode.app"))
        XCTAssertTrue(debugString.contains("/Users/test/node_modules"))
    }
}
