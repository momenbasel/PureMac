import AppKit
import XCTest
@testable import PureMac

@MainActor
final class AppStateTests: XCTestCase {
    func testScanForAppFilesTracksLocationsWhileResultsArePending() throws {
        var completion: ((Set<URL>) -> Void)?
        let expectedLocations = ["/one", "/two", "/three"]
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: {
                StubLocations(paths: expectedLocations)
            },
            appFileScanner: { _, locations, pendingCompletion in
                XCTAssertEqual(locations.appSearch.paths, expectedLocations)
                completion = pendingCompletion
            }
        )

        appState.scanForAppFiles(makeApp())

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, expectedLocations.count)

        let pendingCompletion = try XCTUnwrap(completion)
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/B"),
            URL(fileURLWithPath: "/tmp/A")
        ]

        pendingCompletion(urls)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(
            appState.discoveredFiles,
            urls.sorted { $0.path < $1.path }
        )
        XCTAssertEqual(appState.selectedFiles, urls)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, urls.count)
    }

    func testOlderAppScanCannotReplaceNewerAppResults() {
        var completions: [((Set<URL>) -> Void)] = []
        let state = AppState(performStartupTasks: false, appFileScanner: { _, _, completion in
            completions.append(completion)
        })
        state.scanForAppFiles(makeApp())
        state.scanForAppFiles(makeApp())
        let latest: Set<URL> = [URL(fileURLWithPath: "/fixtures/latest")]
        completions[1](latest)
        completions[0]([URL(fileURLWithPath: "/fixtures/stale")])
        XCTAssertEqual(Set(state.discoveredFiles), latest)
        XCTAssertEqual(state.selectedFiles, latest)
    }

    func testFullDiskAccessRetryKeepsUninstallInTrashFlow() async {
        let expectedURLs: Set<URL> = [
            URL(fileURLWithPath: "/Applications/Fixture.app"),
            URL(fileURLWithPath: "/Users/fixture/Library/Containers/com.fixture.app")
        ]
        var receivedURLs: Set<URL> = []
        let invoked = expectation(description: "app file trasher")
        let state = AppState(
            performStartupTasks: false,
            appFileTrasher: { urls, completion in
                receivedURLs = Set(urls)
                completion(urls, false, [], [])
                invoked.fulfill()
            }
        )
        let items = expectedURLs.map {
            CleanableItem(
                name: $0.lastPathComponent,
                path: $0.path,
                size: 100,
                category: .systemJunk,
                isSelected: true,
                lastModified: nil
            )
        }

        await state.retryAfterFullDiskAccess(
            items: items,
            context: .uninstall(appName: "Fixture", failedCount: items.count)
        )
        await fulfillment(of: [invoked], timeout: 1)

        XCTAssertEqual(receivedURLs, expectedURLs)
    }

    func testVisibleSelectionPreservesHiddenRowsAndManualDefaults() {
        let state = AppState(performStartupTasks: false)
        let visible = cleanupItem(selected: false)
        let hidden = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [visible, hidden], totalSize: 200)
        state.setSelection(true, for: [visible])
        XCTAssertTrue(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
        state.setSelection(false, for: [visible])
        XCTAssertFalse(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
    }

    func testScheduledScanWaitsForReviewToLeaveForeground() {
        let state = AppState(performStartupTasks: false)
        let item = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: 100)
        state.scanState = .completed
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: true))
        XCTAssertTrue(state.canRunScheduledScan(isAppActive: false))
        state.showCleanConfirmation = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [item.id])
        XCTAssertEqual(state.scanState, .completed)
    }

    func testManagedDerivedDataRequiresManualSelectionEvenForScheduledCleanup() throws {
        let state = AppState(performStartupTasks: false)
        let managedRoot = try XCTUnwrap(XcodeBuildMCPDerivedDataSupport.managedRoots().first)
        let item = CleanableItem(
            name: "XcodeBuildMCP: Fixture",
            path: managedRoot
                .appendingPathComponent("workspaces/Fixture-\(UUID().uuidString)/DerivedData").path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: false,
            lastModified: .distantPast
        )
        state.categoryResults[.xcodeJunk] = CategoryResult(category: .xcodeJunk, items: [item], totalSize: item.size)
        state.scanState = .completed

        XCTAssertFalse(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, 0)
        state.cleanAll()
        XCTAssertEqual(state.scanState, .completed)
        state.cleanAll(scheduled: true)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.categoryResults[.xcodeJunk]?.items.map(\.id), [item.id])

        state.toggleItem(item)
        XCTAssertTrue(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, item.size)
        state.toggleItem(item)
        XCTAssertFalse(state.isItemSelected(item))
    }

    func testScheduledScanWaitsForActiveOperations() {
        let state = AppState(performStartupTasks: false)
        state.scanState = .cleaning(progress: 0.2)
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.scanState = .idle
        state.isRemovingAppFiles = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
    }

    func testStopScanPreservesCompletedResultsAndDoesNotStopCleaning() {
        let state = AppState(performStartupTasks: false)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [cleanupItem(selected: true)], totalSize: 100)
        state.scanState = .scanning(progress: 0.5, currentCategory: "User Cache")
        state.cancelScan()
        XCTAssertTrue(state.scanWasCancelled)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.totalItemCount, 1)
        state.scanState = .cleaning(progress: 0.5)
        state.cancelScan()
        XCTAssertEqual(state.scanState, .cleaning(progress: 0.5))
    }

    func testCategoryCleanReturnsToResultsWhileOtherCategoriesRemain() async throws {
        let state = try await stateAfterCleaningUserCache(otherCategoryRemains: true)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertNil(state.categoryResults[.userCache])
        XCTAssertNotNil(state.categoryResults[.trashBins])
        XCTAssertEqual(state.lastCleanedCategory, .userCache)
        XCTAssertEqual(state.totalFreedSpace, 4096)
        XCTAssertFalse(state.adminPassInProgress)
    }

    func testCategoryCleanShowsCompletionWhenNothingRemains() async throws {
        let state = try await stateAfterCleaningUserCache(otherCategoryRemains: false)
        XCTAssertEqual(state.scanState, .cleaned)
        XCTAssertTrue(state.categoryResults.isEmpty)
    }

    private func stateAfterCleaningUserCache(otherCategoryRemains: Bool) async throws -> AppState {
        let savedExclusions = UserDefaults.standard.stringArray(forKey: CleanupExclusions.defaultsKey)
        UserDefaults.standard.set([], forKey: CleanupExclusions.defaultsKey)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PureMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let savedExclusions {
                UserDefaults.standard.set(savedExclusions, forKey: CleanupExclusions.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CleanupExclusions.defaultsKey)
            }
        }
        let file = root.appendingPathComponent("cache.bin")
        try Data(repeating: 1, count: 4096).write(to: file)

        let state = AppState(performStartupTasks: false)
        let item = CleanableItem(name: "Fixture", path: file.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: 4096)
        if otherCategoryRemains {
            let other = CleanableItem(name: "Other", path: "/fixtures/\(UUID().uuidString)", size: 100, category: .trashBins, isSelected: false, lastModified: nil)
            state.categoryResults[.trashBins] = CategoryResult(category: .trashBins, items: [other], totalSize: 100)
        }
        state.scanState = .completed

        state.cleanCategory(.userCache)
        for _ in 0..<200 where state.scanState.isActive {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        return state
    }

    func testCategoryCleanKeepsUnselectedItemsInTheSameCategory() async throws {
        try await withCacheFixture { root in
            let cleanedFile = root.appendingPathComponent("clean.bin")
            let keptFile = root.appendingPathComponent("keep.bin")
            try Data(repeating: 1, count: 4096).write(to: cleanedFile)
            try Data(repeating: 1, count: 4096).write(to: keptFile)
            let cleaned = CleanableItem(name: "Clean", path: cleanedFile.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)
            let kept = CleanableItem(name: "Keep", path: keptFile.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)
            let state = AppState(performStartupTasks: false)
            state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [cleaned, kept], totalSize: 8192)
            state.scanState = .completed

            state.cleanCategory(.userCache, itemIDs: [cleaned.id])
            try await self.waitForCleanToFinish(state)

            XCTAssertEqual(state.scanState, .completed)
            XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [kept.id])
            XCTAssertEqual(state.totalJunkSize, 4096)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))
        }
    }

    func testCategoryCleanShowsSummaryWhenAnItemFails() async throws {
        try await withCacheFixture { root in
            let file = root.appendingPathComponent("clean.bin")
            let target = root.appendingPathComponent("target.bin")
            let link = root.appendingPathComponent("link.bin")
            try Data(repeating: 1, count: 4096).write(to: file)
            try Data(repeating: 1, count: 4096).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let cleaned = CleanableItem(name: "Clean", path: file.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)
            let refused = CleanableItem(name: "Link", path: link.path, size: 4096, category: .userCache, isSelected: true, lastModified: nil)
            let state = AppState(performStartupTasks: false)
            state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [cleaned, refused], totalSize: 8192)
            state.scanState = .completed

            state.cleanCategory(.userCache)
            try await self.waitForCleanToFinish(state)

            XCTAssertEqual(state.scanState, .cleaned)
            XCTAssertTrue(state.lastCleanupHadFailures)
            XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [refused.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func waitForCleanToFinish(_ state: AppState) async throws {
        for _ in 0..<200 where state.scanState.isActive {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(state.scanState.isActive, "Clean did not finish within 5 seconds")
    }

    private func withCacheFixture(_ body: (URL) async throws -> Void) async throws {
        let savedExclusions = UserDefaults.standard.stringArray(forKey: CleanupExclusions.defaultsKey)
        UserDefaults.standard.set([], forKey: CleanupExclusions.defaultsKey)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PureMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let savedExclusions {
                UserDefaults.standard.set(savedExclusions, forKey: CleanupExclusions.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CleanupExclusions.defaultsKey)
            }
        }
        try await body(root)
    }

    private func cleanupItem(selected: Bool) -> CleanableItem {
        CleanableItem(name: "Fixture", path: "/fixtures/\(UUID().uuidString)", size: 100, category: .userCache, isSelected: selected, lastModified: nil)
    }

    private func makeApp() -> InstalledApp {
        InstalledApp(
            id: UUID(),
            appName: "PureMac",
            bundleIdentifier: "com.puremac.app",
            path: URL(fileURLWithPath: "/Applications/PureMac.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
    }
}

private final class StubLocations: Locations {
    init(paths: [String]) {
        super.init()
        appSearch = SearchCategory(name: "Apps", paths: paths)
    }
}
