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

final class XcodeBuildMCPStorageTests: XCTestCase {
    func testXcodeJunkIncludesManagedDerivedDataForEachWorkspace() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let workspaceRoot = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe", isDirectory: true)
        let derivedData = workspaceRoot.appendingPathComponent("DerivedData", isDirectory: true)
        let logs = workspaceRoot.appendingPathComponent("logs", isDirectory: true)
        let outsideDirectory = temporaryHome.appendingPathComponent("outside", isDirectory: true)
        let symlinkedDerivedData = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/Symlinked-111111111111/DerivedData")
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: symlinkedDerivedData.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkedDerivedData, withDestinationURL: outsideDirectory)
        try Data(repeating: 0xAB, count: 4_096)
            .write(to: derivedData.appendingPathComponent("build-product"))
        try Data(repeating: 0xCD, count: 4_096)
            .write(to: logs.appendingPathComponent("build.log"))
        try Data(repeating: 0xEF, count: 4_096)
            .write(to: outsideDirectory.appendingPathComponent("must-not-be-scanned"))

        let engine = ScanEngine(homeDirectory: temporaryHome)
        let result = await engine.scanCategory(.xcodeJunk)

        let expectedPath = derivedData.resolvingSymlinksInPath().path
        let item = try XCTUnwrap(
            result.items.first {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == expectedPath
            },
            "Expected \(expectedPath); scanned: \(result.items.map(\.path))"
        )
        XCTAssertEqual(item.name, "XcodeBuildMCP: PureMac")
        XCTAssertTrue(item.isSelected)
        XCTAssertFalse(result.items.contains { $0.path == logs.path })
        XCTAssertFalse(result.items.contains { $0.path == symlinkedDerivedData.path })
    }

    func testSymlinkedXcodeBuildMCPRootIsNotScanned() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-RootLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let externalRoot = temporaryHome
            .appendingPathComponent("Library/Application Support/FakeXcodeBuildMCP", isDirectory: true)
        let externalDerivedData = externalRoot
            .appendingPathComponent("workspaces/Foreign-222222222222/DerivedData", isDirectory: true)
        let developerDirectory = temporaryHome
            .appendingPathComponent("Library/Developer", isDirectory: true)
        let managedRoot = developerDirectory.appendingPathComponent("XcodeBuildMCP", isDirectory: true)
        try fileManager.createDirectory(at: externalDerivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: developerDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: managedRoot, withDestinationURL: externalRoot)
        try Data(repeating: 0xAA, count: 4_096)
            .write(to: externalDerivedData.appendingPathComponent("foreign-data"))

        let result = await ScanEngine(homeDirectory: temporaryHome).scanCategory(.xcodeJunk)

        XCTAssertFalse(result.items.contains { $0.name.hasPrefix("XcodeBuildMCP:") })
    }

    func testCleaningRejectsManagedPathWhoseRootResolvesOutsideManagedStorage() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-CleanRootLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let externalRoot = temporaryHome
            .appendingPathComponent("Library/Application Support/FakeXcodeBuildMCP", isDirectory: true)
        let externalDerivedData = externalRoot
            .appendingPathComponent("workspaces/Foreign-222222222222/DerivedData", isDirectory: true)
        let developerDirectory = temporaryHome
            .appendingPathComponent("Library/Developer", isDirectory: true)
        let managedRoot = developerDirectory.appendingPathComponent("XcodeBuildMCP", isDirectory: true)
        let apparentDerivedData = managedRoot
            .appendingPathComponent("workspaces/Foreign-222222222222/DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: externalDerivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: developerDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: managedRoot, withDestinationURL: externalRoot)
        try Data(repeating: 0xBB, count: 4_096)
            .write(to: externalDerivedData.appendingPathComponent("foreign-data"))

        let item = CleanableItem(
            name: "XcodeBuildMCP: Foreign",
            path: apparentDerivedData.path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )
        let result = await CleaningEngine(homeDirectory: temporaryHome)
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: externalDerivedData.path))
    }

    func testXcodeJunkIncludesLegacySharedDerivedData() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-Legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let legacyDerivedData = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: legacyDerivedData, withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 4_096)
            .write(to: legacyDerivedData.appendingPathComponent("legacy-build-product"))

        let result = await ScanEngine(homeDirectory: temporaryHome).scanCategory(.xcodeJunk)
        let expectedPath = legacyDerivedData.resolvingSymlinksInPath().path
        let item = try XCTUnwrap(result.items.first {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == expectedPath
        })

        XCTAssertEqual(item.name, "XcodeBuildMCP: Legacy DerivedData")
        XCTAssertTrue(item.isSelected)
    }

    func testCleaningManagedDerivedDataLeavesWorkspaceStateIntact() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-Clean-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let workspaceRoot = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe", isDirectory: true)
        let derivedData = workspaceRoot.appendingPathComponent("DerivedData", isDirectory: true)
        let preservedDirectories = ["logs", "state", "locks", "result-bundles", "test-products"].map {
            workspaceRoot.appendingPathComponent($0, isDirectory: true)
        }
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        for directory in preservedDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0xCD, count: 256)
                .write(to: directory.appendingPathComponent("must-survive"))
        }
        try Data(repeating: 0xAB, count: 4_096)
            .write(to: derivedData.appendingPathComponent("build-product"))

        let scan = await ScanEngine(homeDirectory: temporaryHome).scanCategory(.xcodeJunk)
        let item = try XCTUnwrap(scan.items.first { $0.name == "XcodeBuildMCP: PureMac" })
        let result = await CleaningEngine(homeDirectory: temporaryHome)
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: derivedData.path))
        XCTAssertEqual(result.trashedPaths.count, 1)
        let trashedPath = try XCTUnwrap(result.trashedPaths.first)
        XCTAssertTrue(fileManager.fileExists(atPath: trashedPath))
        XCTAssertTrue(
            trashedPath.hasPrefix(
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash", isDirectory: true)
                    .path + "/"
            )
        )
        try? fileManager.removeItem(atPath: trashedPath)
        for directory in preservedDirectories {
            XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("must-survive").path))
        }
    }

    func testManagedDerivedDataSafetyOnlyAllowsDerivedDataDirectories() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let managedRoot = "/Users/tester/Library/Developer/XcodeBuildMCP"

        XCTAssertTrue(XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            "\(managedRoot)/workspaces/PureMac-59316969cafe/DerivedData",
            homeDirectory: home
        ))
        XCTAssertTrue(XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            "\(managedRoot)/DerivedData",
            homeDirectory: home
        ))
        XCTAssertFalse(XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            "\(managedRoot)/workspaces/PureMac-59316969cafe/logs",
            homeDirectory: home
        ))
        XCTAssertFalse(XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            "\(managedRoot)/workspaces/PureMac-59316969cafe",
            homeDirectory: home
        ))
        XCTAssertFalse(XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            "\(managedRoot)-backup/workspaces/PureMac-59316969cafe/DerivedData",
            homeDirectory: home
        ))
    }

    func testSymlinkedHomeScanOutputCanStillBeCleaned() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-HomeLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: container) }

        let realHome = container.appendingPathComponent("real-home", isDirectory: true)
        let linkedHome = container.appendingPathComponent("linked-home", isDirectory: true)
        let derivedData = realHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        try Data(repeating: 0xA1, count: 4_096)
            .write(to: derivedData.appendingPathComponent("build-product"))

        let scan = await ScanEngine(homeDirectory: linkedHome).scanCategory(.xcodeJunk)
        let item = try XCTUnwrap(scan.items.first { $0.name == "XcodeBuildMCP: PureMac" })
        let result = await CleaningEngine(homeDirectory: linkedHome).cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: derivedData.path))
    }

    func testCleaningRejectsDerivedDataSymlinkToAnotherManagedWorkspace() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-ManagedLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let workspaces = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces", isDirectory: true)
        let sourceWorkspace = workspaces.appendingPathComponent("Source-111111111111", isDirectory: true)
        let targetDerivedData = workspaces
            .appendingPathComponent("Target-222222222222/DerivedData", isDirectory: true)
        let apparentDerivedData = sourceWorkspace.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: sourceWorkspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: targetDerivedData, withIntermediateDirectories: true)
        try Data(repeating: 0xB2, count: 4_096)
            .write(to: targetDerivedData.appendingPathComponent("must-survive"))
        try fileManager.createSymbolicLink(at: apparentDerivedData, withDestinationURL: targetDerivedData)

        let item = CleanableItem(
            name: "XcodeBuildMCP: Source",
            path: apparentDerivedData.path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )
        let result = await CleaningEngine(homeDirectory: temporaryHome).cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: targetDerivedData.appendingPathComponent("must-survive").path))
    }

    func testAdministratorCleaningNeverEscalatesManagedDerivedData() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-NoAdmin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let derivedData = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData", isDirectory: true)
        let marker = derivedData.appendingPathComponent("must-survive")
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 4_096).write(to: marker)
        let item = CleanableItem(
            name: "XcodeBuildMCP: PureMac",
            path: derivedData.path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine(homeDirectory: temporaryHome)
            .cleanWithAdminPrivileges(items: [item])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    }

    func testCleaningSkipsDerivedDataWhenLifecycleLockIsHeld() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-Lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let workspaceRoot = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe", isDirectory: true)
        let derivedData = workspaceRoot.appendingPathComponent("DerivedData", isDirectory: true)
        let lockDir = workspaceRoot
            .appendingPathComponent("locks/filesystem-lifecycle.lock", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4_096)
            .write(to: derivedData.appendingPathComponent("build-product"))

        let nowMs = Date().timeIntervalSince1970 * 1000
        let owner: [String: Any] = [
            "token": UUID().uuidString,
            "pid": Int(getpid()),
            "purpose": "filesystem-lifecycle",
            "acquiredAtMs": nowMs,
            "expiresAtMs": nowMs + 600_000,
        ]
        let ownerData = try JSONSerialization.data(withJSONObject: owner)
        try ownerData.write(to: lockDir.appendingPathComponent("owner.json"))

        let item = CleanableItem(
            name: "XcodeBuildMCP: PureMac",
            path: derivedData.path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )
        let result = await CleaningEngine(homeDirectory: temporaryHome)
            .cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: derivedData.appendingPathComponent("build-product").path))
    }

    func testLifecycleLockDetectionMatchesXcodeBuildMCPOwnerFile() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-LockDetect-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let derivedData = temporaryHome
            .appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData", isDirectory: true)
        let lockDir = temporaryHome
            .appendingPathComponent(
                "Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/locks/filesystem-lifecycle.lock",
                isDirectory: true
            )
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)

        XCTAssertFalse(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )

        try fileManager.createDirectory(at: lockDir, withIntermediateDirectories: true)
        // A fresh lock directory without owner.json is treated as held — same
        // conservative stance XcodeBuildMCP takes within the lease window.
        XCTAssertTrue(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )

        let nowMs = Date().timeIntervalSince1970 * 1000
        let expiredOwner: [String: Any] = [
            "token": "abc",
            "pid": 4242,
            "purpose": "purge",
            "acquiredAtMs": nowMs - 1_200_000,
            "expiresAtMs": nowMs - 600_000,
        ]
        try JSONSerialization.data(withJSONObject: expiredOwner)
            .write(to: lockDir.appendingPathComponent("owner.json"))

        XCTAssertFalse(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )

        let liveOwner: [String: Any] = [
            "token": "def",
            "pid": 4242,
            "purpose": "purge",
            "acquiredAtMs": nowMs,
            "expiresAtMs": nowMs + 60_000,
        ]
        try JSONSerialization.data(withJSONObject: liveOwner)
            .write(to: lockDir.appendingPathComponent("owner.json"))

        XCTAssertTrue(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )
    }

    func testLifecycleLockAcquisitionIsExclusive() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-LockAcquire-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let derivedData = temporaryHome
            .appendingPathComponent(
                "Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData",
                isDirectory: true
            )
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)

        let first = XcodeBuildMCPDerivedDataSupport.acquireLifecycleLock(
            forManagedDerivedDataPath: derivedData.path,
            homeDirectory: temporaryHome,
            fileManager: fileManager
        )
        XCTAssertNotNil(first)
        XCTAssertTrue(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager
            )
        )

        let second = XcodeBuildMCPDerivedDataSupport.acquireLifecycleLock(
            forManagedDerivedDataPath: derivedData.path,
            homeDirectory: temporaryHome,
            fileManager: fileManager
        )
        XCTAssertNil(second)

        if let first {
            XcodeBuildMCPDerivedDataSupport.releaseLifecycleLock(
                first,
                fileManager: fileManager
            )
        }
        XCTAssertFalse(
            XcodeBuildMCPDerivedDataSupport.isLifecycleLockHeld(
                forManagedDerivedDataPath: derivedData.path,
                homeDirectory: temporaryHome,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )
    }

    func testSymlinkedHomeAllowlistsOrdinaryCachesConsistently() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-CacheHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: container) }

        let realHome = container.appendingPathComponent("real-home", isDirectory: true)
        let linkedHome = container.appendingPathComponent("linked-home", isDirectory: true)
        let cacheDir = realHome.appendingPathComponent("Library/Caches/com.example.junk", isDirectory: true)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        try Data(repeating: 0x11, count: 4_096)
            .write(to: cacheDir.appendingPathComponent("blob"))

        let item = CleanableItem(
            name: "com.example.junk",
            path: cacheDir.path,
            size: 4_096,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )
        let result = await CleaningEngine(homeDirectory: linkedHome).cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: cacheDir.appendingPathComponent("blob").path))
    }

    func testScheduledAutoCleanAllowsOldUnlockedManagedDerivedData() {
        let item = CleanableItem(
            name: "XcodeBuildMCP: PureMac",
            path: "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData",
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(
            XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(
                item,
                homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
                now: Date(timeIntervalSince1970: XcodeBuildMCPDerivedDataSupport.scheduledCleanupAge + 1)
            )
        )
    }

    func testScheduledAutoCleanRejectsRecentManagedDerivedData() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let item = CleanableItem(
            name: "XcodeBuildMCP: PureMac",
            path: "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData",
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: now.addingTimeInterval(-XcodeBuildMCPDerivedDataSupport.scheduledCleanupAge + 1)
        )

        XCTAssertFalse(
            XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(
                item,
                homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
                now: now
            )
        )
    }

    func testScheduledAutoCleanRejectsManagedDerivedDataWithActiveLifecycleLock() throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-XcodeBuildMCP-ScheduledLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let derivedData = temporaryHome.appendingPathComponent(
            "Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/DerivedData",
            isDirectory: true
        )
        let lockDir = temporaryHome.appendingPathComponent(
            "Library/Developer/XcodeBuildMCP/workspaces/PureMac-59316969cafe/locks/filesystem-lifecycle.lock",
            isDirectory: true
        )
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: lockDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 10_000_000)
        let owner: [String: Any] = [
            "token": UUID().uuidString,
            "pid": 4242,
            "purpose": "filesystem-lifecycle",
            "acquiredAtMs": (now.timeIntervalSince1970 - 60) * 1000,
            "expiresAtMs": (now.timeIntervalSince1970 + 60) * 1000,
        ]
        try JSONSerialization.data(withJSONObject: owner)
            .write(to: lockDir.appendingPathComponent("owner.json"))

        let item = CleanableItem(
            name: "XcodeBuildMCP: PureMac",
            path: derivedData.path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: now.addingTimeInterval(-XcodeBuildMCPDerivedDataSupport.scheduledCleanupAge - 1)
        )

        XCTAssertFalse(
            XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(
                item,
                homeDirectory: temporaryHome,
                now: now,
                fileManager: fileManager,
                isProcessAlive: { _ in false }
            )
        )
    }

    func testScheduledAutoCleanKeepsOrdinarySelectionSemantics() {
        let ordinary = CleanableItem(
            name: "DerivedData",
            path: "/Users/tester/Library/Developer/Xcode/DerivedData",
            size: 4_096,
            category: .xcodeJunk,
            isSelected: true,
            lastModified: nil
        )
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertTrue(
            XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(ordinary, homeDirectory: home)
        )
    }
}
