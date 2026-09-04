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

    func testScanExclusionsMergeLegacyPathsAndMigrateOnSave() throws {
        let suiteName = "ScanExclusionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["/tmp/legacy-folder"], forKey: ScanExclusions.legacyFoldersKey)
        defaults.set(["/tmp/file", "/tmp/file"], forKey: ScanExclusions.pathsKey)
        let expectedPaths = ["/tmp/file", "/tmp/legacy-folder"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .sorted()

        XCTAssertEqual(
            ScanExclusions.paths(in: defaults),
            expectedPaths
        )

        ScanExclusions.save(ScanExclusions.paths(in: defaults), in: defaults)

        XCTAssertNil(defaults.object(forKey: ScanExclusions.legacyFoldersKey))
        XCTAssertEqual(
            defaults.stringArray(forKey: ScanExclusions.pathsKey),
            expectedPaths
        )
    }

    func testScanExclusionsRespectPathComponentBoundariesAndProtectAncestors() {
        let exclusions = ["/tmp/cache/keep.txt"]

        XCTAssertTrue(ScanExclusions.contains("/tmp/cache/keep.txt", excludedPaths: exclusions))
        XCTAssertFalse(ScanExclusions.contains("/tmp/cache/keep.txt.bak", excludedPaths: exclusions))
        XCTAssertTrue(ScanExclusions.excludes("/tmp/cache", excludedPaths: exclusions))
        XCTAssertFalse(ScanExclusions.excludes("/tmp/cache-old", excludedPaths: exclusions))
    }

    func testScanExclusionsCanonicalizeSymlinkAliases() {
        let uniqueName = "PureMac-scan-exclusion-\(UUID().uuidString)"

        XCTAssertTrue(
            ScanExclusions.contains(
                "/private/tmp/\(uniqueName)",
                excludedPaths: ["/tmp/\(uniqueName)"]
            )
        )
    }

    func testFilteringRecalculatesCategoryTotal() {
        let kept = CleanableItem(
            name: "keep.log",
            path: "/tmp/keep.log",
            size: 100,
            category: .systemJunk,
            isSelected: true,
            lastModified: nil
        )
        let excluded = CleanableItem(
            name: "excluded.log",
            path: "/tmp/excluded.log",
            size: 200,
            category: .systemJunk,
            isSelected: true,
            lastModified: nil
        )
        let result = CategoryResult(
            category: .systemJunk,
            items: [kept, excluded],
            totalSize: 300
        )

        let filtered = ScanExclusions.filtering(result, excludedPaths: [excluded.path])

        XCTAssertEqual(filtered.items, [kept])
        XCTAssertEqual(filtered.totalSize, kept.size)
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
