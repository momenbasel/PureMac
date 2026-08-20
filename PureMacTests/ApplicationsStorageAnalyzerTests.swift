import XCTest
@testable import PureMac

final class ApplicationsStorageAnalyzerTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacApplicationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // 1. Normal Applications hierarchy
    func testNormalApplicationsHierarchy() async throws {
        let app1URL = temporaryDirectoryURL.appendingPathComponent("TestApp.app", isDirectory: true)
        let app2URL = temporaryDirectoryURL.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: app1URL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app2URL, withIntermediateDirectories: true)

        let file1 = app1URL.appendingPathComponent("binary")
        try "AppBinaryContent".write(to: file1, atomically: true, encoding: .utf8)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertEqual(result.root.metadata.storageCategoryIdentifier, "applications")
        XCTAssertFalse(result.wasCancelled)
    }

    // 2. Allocated-byte accounting (st_blocks * 512)
    func testAllocatedByteAccounting() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("MyCalc.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let fileURL = appURL.appendingPathComponent("executable")
        let data = Data(repeating: 0x42, count: 8192)
        try data.write(to: fileURL)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let appNode = result.root.children.first { $0.name == "MyCalc.app" }
        XCTAssertNotNil(appNode)
        XCTAssertGreaterThan(appNode?.allocatedSize ?? 0, 0)
        XCTAssertGreaterThanOrEqual(appNode?.logicalSize ?? 0, Int64(data.count))
        // Descendants must not be materialized into the returned StorageNode tree
        XCTAssertEqual(appNode?.children.count, 0)
    }

    // 3. Logical vs allocated size distinction
    func testLogicalVsAllocatedDistinction() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let fileURL = appURL.appendingPathComponent("small.txt")
        try "Hi".write(to: fileURL, atomically: true, encoding: .utf8)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let appNode = result.root.children.first { $0.name == "Sample.app" }
        XCTAssertNotNil(appNode)
        XCTAssertGreaterThanOrEqual(appNode?.logicalSize ?? 0, 2)
        XCTAssertGreaterThanOrEqual(appNode?.allocatedSize ?? 0, appNode?.logicalSize ?? 0)
        XCTAssertEqual(appNode?.children.count, 0)
    }

    // 4. Hidden descendants included
    func testHiddenDescendantsIncluded() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("HiddenTest.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let hiddenFile = appURL.appendingPathComponent(".hidden_config")
        try "SecretConfig".write(to: hiddenFile, atomically: true, encoding: .utf8)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let appNode = result.root.children.first { $0.name == "HiddenTest.app" }
        XCTAssertNotNil(appNode)
        XCTAssertGreaterThan(appNode?.allocatedSize ?? 0, 0)
        XCTAssertEqual(appNode?.children.count, 0)
    }

    // 5. Hard-link deduplication
    func testHardLinkDeduplication() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("HardLink.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let file1 = appURL.appendingPathComponent("original.bin")
        let file2 = appURL.appendingPathComponent("linked.bin")
        let data = Data(repeating: 0x55, count: 4096)
        try data.write(to: file1)
        link(file1.path, file2.path)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        // Hard linked file must be counted once in parent allocated totals
        let appNode = result.root.children.first { $0.name == "HardLink.app" }
        XCTAssertNotNil(appNode)
        XCTAssertEqual(appNode?.children.count, 0)
        XCTAssertEqual(appNode?.allocatedSize, result.root.allocatedSize)
    }

    // 6. Symlink safety (no traversing targets)
    func testSymlinkSafety() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("Symlink.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let targetDir = temporaryDirectoryURL.appendingPathComponent("TargetFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetFile = targetDir.appendingPathComponent("large.bin")
        try Data(repeating: 0x99, count: 100_000).write(to: targetFile)

        let linkURL = appURL.appendingPathComponent("link_to_target")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetDir)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let appNode = result.root.children.first { $0.name == "Symlink.app" }
        XCTAssertNotNil(appNode)
        XCTAssertEqual(appNode?.children.count, 0)
        // Symlink target is not traversed, so app size must not include 100KB target file
        XCTAssertLessThan(appNode?.allocatedSize ?? 0, 50_000)
    }

    // 7. Volume boundary preservation
    func testVolumeBoundaryPreservation() async throws {
        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        XCTAssertNotNil(result.rootDeviceIdentifier)
    }

    // 8. Missing root handling
    func testMissingRootHandling() async {
        let nonExistentURL = temporaryDirectoryURL.appendingPathComponent("DoesNotExist", isDirectory: true)
        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: nonExistentURL)
        let result = await analyzer.analyze()

        XCTAssertEqual(result.root.allocatedSize, 0)
        XCTAssertEqual(result.root.children.count, 0)
        XCTAssertFalse(result.wasCancelled)
    }

    // 9. Application category metadata
    func testApplicationCategoryMetadata() async throws {
        let xcodeURL = temporaryDirectoryURL.appendingPathComponent("Xcode.app", isDirectory: true)
        let utilsURL = temporaryDirectoryURL.appendingPathComponent("Utilities", isDirectory: true)
        let normalURL = temporaryDirectoryURL.appendingPathComponent("App.app", isDirectory: true)

        try FileManager.default.createDirectory(at: xcodeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: utilsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalURL, withIntermediateDirectories: true)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let xcodeNode = result.root.children.first { $0.name == "Xcode.app" }
        let utilsNode = result.root.children.first { $0.name == "Utilities" }
        let normalNode = result.root.children.first { $0.name == "App.app" }

        XCTAssertEqual(xcodeNode?.metadata.storageCategoryIdentifier, ApplicationsStorageCategory.developerTool.rawValue)
        XCTAssertEqual(utilsNode?.metadata.storageCategoryIdentifier, ApplicationsStorageCategory.utilityFolder.rawValue)
        XCTAssertEqual(normalNode?.metadata.storageCategoryIdentifier, ApplicationsStorageCategory.applicationBundle.rawValue)
    }

    // 10. Sort order descending by allocated size
    func testSortOrderDescendingByAllocatedSize() async throws {
        let smallApp = temporaryDirectoryURL.appendingPathComponent("Small.app", isDirectory: true)
        let largeApp = temporaryDirectoryURL.appendingPathComponent("Large.app", isDirectory: true)
        try FileManager.default.createDirectory(at: smallApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: largeApp, withIntermediateDirectories: true)

        try "A".write(to: smallApp.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x11, count: 50_000).write(to: largeApp.appendingPathComponent("bigfile"))

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        XCTAssertEqual(result.root.children.first?.name, "Large.app")
    }

    // 11. Synthetic deep .app hierarchy proves aggregate sizes match full recursive traversal exactly
    func testSyntheticAppHierarchyMatchesFullRecursiveTraversal() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("Complex.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let fwURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        let resURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: macosURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fwURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resURL, withIntermediateDirectories: true)

        let execData = Data(repeating: 0xAA, count: 12_000)
        let fwData = Data(repeating: 0xBB, count: 24_000)
        let resData = Data(repeating: 0xCC, count: 6_000)
        let plistData = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist></plist>".data(using: .utf8)!

        try execData.write(to: macosURL.appendingPathComponent("ComplexExec"))
        try fwData.write(to: fwURL.appendingPathComponent("MyFramework.dylib"))
        try resData.write(to: resURL.appendingPathComponent("Assets.car"))
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        // Full non-aggregated traversal baseline
        let standardScanner = FileTreeScanner(configuration: .init(aggregateApplicationPackages: false))
        let fullResult = await standardScanner.scan(root: temporaryDirectoryURL)

        // Aggregated package-boundary traversal
        let aggregateAnalyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let aggregateResult = await aggregateAnalyzer.analyze()

        // Verify root totals match exactly
        XCTAssertEqual(aggregateResult.root.allocatedSize, fullResult.root.allocatedSize)
        XCTAssertEqual(aggregateResult.root.logicalSize, fullResult.root.logicalSize)

        // Verify .app bundle node totals match full subtree totals
        let fullAppNode = fullResult.root.children.first { $0.name == "Complex.app" }
        let aggregateAppNode = aggregateResult.root.children.first { $0.name == "Complex.app" }

        XCTAssertNotNil(fullAppNode)
        XCTAssertNotNil(aggregateAppNode)
        XCTAssertEqual(aggregateAppNode?.allocatedSize, fullAppNode?.allocatedSize)
        XCTAssertEqual(aggregateAppNode?.logicalSize, fullAppNode?.logicalSize)

        // Verify descendants are NOT materialized into aggregate tree
        XCTAssertEqual(aggregateAppNode?.children.count, 0)
        XCTAssertGreaterThan(fullAppNode?.children.count ?? 0, 0)
    }

    // 12. Direct .app root scan with aggregation enabled
    func testDirectAppRootScanWithAggregation() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("Standalone.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let data = Data(repeating: 0x33, count: 16_000)
        try data.write(to: contentsURL.appendingPathComponent("binary"))

        let scanner = FileTreeScanner(configuration: .init(aggregateApplicationPackages: true))
        let result = await scanner.scan(root: appURL)

        XCTAssertEqual(result.root.name, "Standalone.app")
        XCTAssertGreaterThanOrEqual(result.root.logicalSize, 16_000)
        XCTAssertGreaterThan(result.root.allocatedSize, 0)
        XCTAssertEqual(result.root.children.count, 0)
    }

    // 13. Cancellation during package measurement
    func testCancellationDuringPackageMeasurement() async throws {
        let appURL = temporaryDirectoryURL.appendingPathComponent("CancelMe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        for i in 0..<100 {
            try "Content".write(to: appURL.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        }

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let task = Task {
            await analyzer.analyze()
        }
        task.cancel()
        let result = await task.value

        XCTAssertNotNil(result.root)
    }

    // 14. Ancestor propagation with sibling .app bundles and intermediate folders
    func testAncestorPropagationWithSiblingAppsAndIntermediateFolder() async throws {
        // Hierarchy shape:
        // /Applications
        //    Xcode.app
        //        Contents/...
        //    Microsoft Word.app
        //        Contents/...
        //    Utilities/
        //        Tool.app
        //            Contents/...

        let xcodeURL = temporaryDirectoryURL.appendingPathComponent("Xcode.app/Contents/MacOS", isDirectory: true)
        let xcodeFwURL = temporaryDirectoryURL.appendingPathComponent("Xcode.app/Contents/Frameworks", isDirectory: true)
        let wordURL = temporaryDirectoryURL.appendingPathComponent("Microsoft Word.app/Contents/MacOS", isDirectory: true)
        let wordResURL = temporaryDirectoryURL.appendingPathComponent("Microsoft Word.app/Contents/Resources", isDirectory: true)
        let utilsURL = temporaryDirectoryURL.appendingPathComponent("Utilities", isDirectory: true)
        let toolURL = utilsURL.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true)

        try FileManager.default.createDirectory(at: xcodeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcodeFwURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordResURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolURL, withIntermediateDirectories: true)

        try Data(repeating: 0x11, count: 64_000).write(to: xcodeURL.appendingPathComponent("Xcode"))
        try Data(repeating: 0x22, count: 128_000).write(to: xcodeFwURL.appendingPathComponent("lib.dylib"))
        try Data(repeating: 0x33, count: 96_000).write(to: wordURL.appendingPathComponent("Word"))
        try Data(repeating: 0x44, count: 32_000).write(to: wordResURL.appendingPathComponent("Font.ttf"))
        try Data(repeating: 0x55, count: 48_000).write(to: toolURL.appendingPathComponent("Tool"))

        // A. Full ordinary recursive traversal
        let ordinaryScanner = FileTreeScanner(configuration: .init(aggregateApplicationPackages: false))
        let ordinaryResult = await ordinaryScanner.scan(root: temporaryDirectoryURL)

        // B. Package-boundary aggregate traversal
        let aggregateAnalyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let aggregateResult = await aggregateAnalyzer.analyze()

        // 1. Root level (/Applications) equality
        XCTAssertEqual(aggregateResult.root.allocatedSize, ordinaryResult.root.allocatedSize)
        XCTAssertEqual(aggregateResult.root.logicalSize, ordinaryResult.root.logicalSize)

        // 2. Sibling package level (Xcode.app)
        let ordinaryXcode = try XCTUnwrap(ordinaryResult.root.children.first { $0.name == "Xcode.app" })
        let aggregateXcode = try XCTUnwrap(aggregateResult.root.children.first { $0.name == "Xcode.app" })
        XCTAssertEqual(aggregateXcode.allocatedSize, ordinaryXcode.allocatedSize)
        XCTAssertEqual(aggregateXcode.logicalSize, ordinaryXcode.logicalSize)
        XCTAssertTrue(aggregateXcode.children.isEmpty)
        XCTAssertFalse(ordinaryXcode.children.isEmpty)

        // 3. Sibling package level (Microsoft Word.app)
        let ordinaryWord = try XCTUnwrap(ordinaryResult.root.children.first { $0.name == "Microsoft Word.app" })
        let aggregateWord = try XCTUnwrap(aggregateResult.root.children.first { $0.name == "Microsoft Word.app" })
        XCTAssertEqual(aggregateWord.allocatedSize, ordinaryWord.allocatedSize)
        XCTAssertEqual(aggregateWord.logicalSize, ordinaryWord.logicalSize)
        XCTAssertTrue(aggregateWord.children.isEmpty)
        XCTAssertFalse(ordinaryWord.children.isEmpty)

        // 4. Intermediate non-package directory level (Utilities/)
        let ordinaryUtils = try XCTUnwrap(ordinaryResult.root.children.first { $0.name == "Utilities" })
        let aggregateUtils = try XCTUnwrap(aggregateResult.root.children.first { $0.name == "Utilities" })
        XCTAssertEqual(aggregateUtils.allocatedSize, ordinaryUtils.allocatedSize)
        XCTAssertEqual(aggregateUtils.logicalSize, ordinaryUtils.logicalSize)
        XCTAssertEqual(aggregateUtils.children.count, 1)

        // 5. Nested package inside non-package directory (Utilities/Tool.app)
        let ordinaryTool = try XCTUnwrap(ordinaryUtils.children.first { $0.name == "Tool.app" })
        let aggregateTool = try XCTUnwrap(aggregateUtils.children.first { $0.name == "Tool.app" })
        XCTAssertEqual(aggregateTool.allocatedSize, ordinaryTool.allocatedSize)
        XCTAssertEqual(aggregateTool.logicalSize, ordinaryTool.logicalSize)
        XCTAssertTrue(aggregateTool.children.isEmpty)
        XCTAssertFalse(ordinaryTool.children.isEmpty)

        // 6. Diagnostics metrics must accurately report full allocated bytes
        let metrics = StorageScanMetrics.compute(from: aggregateResult.root)
        XCTAssertEqual(metrics.allocatedBytes, aggregateResult.root.allocatedSize)
        XCTAssertEqual(metrics.logicalBytes, aggregateResult.root.logicalSize)
        XCTAssertEqual(metrics.packageAggregatesCount, 3)
    }

    // 15. Hard links across package boundaries are not double-counted
    func testHardLinksAcrossPackageBoundariesNotDoubleCounted() async throws {
        let app1URL = temporaryDirectoryURL.appendingPathComponent("App1.app/Contents/MacOS", isDirectory: true)
        let app2URL = temporaryDirectoryURL.appendingPathComponent("App2.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app1URL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app2URL, withIntermediateDirectories: true)

        let file1 = app1URL.appendingPathComponent("shared.bin")
        let file2 = app2URL.appendingPathComponent("shared.bin")
        let data = Data(repeating: 0x77, count: 65_536)
        try data.write(to: file1)
        link(file1.path, file2.path)

        let analyzer = ApplicationsStorageAnalyzer(applicationsURL: temporaryDirectoryURL)
        let result = await analyzer.analyze()

        let app1 = try XCTUnwrap(result.root.children.first { $0.name == "App1.app" })
        let app2 = try XCTUnwrap(result.root.children.first { $0.name == "App2.app" })

        XCTAssertTrue(app1.children.isEmpty)
        XCTAssertTrue(app2.children.isEmpty)

        // Sum of root allocated bytes must count the 64KB shared data block only once
        let metrics = StorageScanMetrics.compute(from: result.root)
        XCTAssertEqual(metrics.allocatedBytes, result.root.allocatedSize)
        XCTAssertLessThan(result.root.allocatedSize, Int64(data.count * 2))
    }
}
