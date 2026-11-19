import XCTest
@testable import PureMac

final class AIAppsCleanupTests: XCTestCase {
    private let fileManager = FileManager.default
    private var fixtureHome: URL!

    override func setUpWithError() throws {
        fixtureHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-AIApps-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureHome, fileManager.fileExists(atPath: fixtureHome.path) {
            try fileManager.removeItem(at: fixtureHome)
        }
    }

    func testEveryScannedAIAppTargetCanBeCleaned() async throws {
        let paths = [
            ".ollama/logs",
            ".ollama/history",
            ".lmstudio/server-logs",
            ".lmstudio/conversations",
            "Library/Caches/ollama",
            "Library/Caches/com.electron.ollama",
            "Library/WebKit/com.electron.ollama",
            "Library/Saved Application State/com.electron.ollama.savedState",
        ]
        for path in paths {
            try createData(at: path, directory: path != ".ollama/history")
        }

        let scan = await ScanEngine(homeDirectory: fixtureHome).scanCategory(.aiApps)
        XCTAssertEqual(Set(scan.items.map(\.path)), Set(paths.map { fixtureHome.appendingPathComponent($0).path }))

        let result = await CleaningEngine(homeDirectory: fixtureHome).cleanItems(scan.items) { _ in }

        XCTAssertEqual(result.itemsCleaned, paths.count)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        for path in paths {
            XCTAssertFalse(fileManager.fileExists(atPath: fixtureHome.appendingPathComponent(path).path))
        }
    }

    func testDefaultSelectionPreservesHistoryConversationsAndModels() async throws {
        let retained = [".ollama/history", ".lmstudio/conversations", ".ollama/models", ".lmstudio/models", ".ollama/id_ed25519"]
        for path in retained + [".ollama/logs", ".lmstudio/server-logs"] {
            try createData(at: path, directory: path != ".ollama/history" && path != ".ollama/id_ed25519")
        }

        let scan = await ScanEngine(homeDirectory: fixtureHome).scanCategory(.aiApps)
        let history = try XCTUnwrap(scan.items.first { $0.path.hasSuffix("/.ollama/history") })
        let conversations = try XCTUnwrap(scan.items.first { $0.path.hasSuffix("/.lmstudio/conversations") })
        XCTAssertFalse(history.isSelected)
        XCTAssertFalse(conversations.isSelected)

        let result = await CleaningEngine(homeDirectory: fixtureHome).cleanCategory(scan) { _ in }

        XCTAssertEqual(result.itemsCleaned, 2)
        XCTAssertTrue(result.errors.isEmpty)
        for path in retained {
            XCTAssertTrue(fileManager.fileExists(atPath: fixtureHome.appendingPathComponent(path).path))
        }
    }

    func testAIAppCategoryRefusesModelsKeysAncestorsSiblingsAndUnrelatedCaches() async throws {
        let denied = [
            ".ollama/models", ".ollama/id_ed25519", ".lmstudio/models", ".lmstudio/config.json",
            ".ollama/logs-backup", ".lmstudio/server-logs-backup", "Library/Caches/unrelated",
        ]
        for path in denied {
            try createData(at: path)
        }
        let requested = denied + [".ollama", ".lmstudio", "Library/Caches"]
        let items = requested.map { item(at: fixtureHome.appendingPathComponent($0).path) }

        let result = await CleaningEngine(homeDirectory: fixtureHome).cleanItems(items) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, requested.count)
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        for path in requested {
            XCTAssertTrue(fileManager.fileExists(atPath: fixtureHome.appendingPathComponent(path).path))
        }
    }

    func testAIAppCleanupRejectsSymlinkedTargetsAndParents() async throws {
        try createData(at: "Library/Caches/foreign")
        let foreign = fixtureHome.appendingPathComponent("Library/Caches/foreign")
        let ollama = fixtureHome.appendingPathComponent(".ollama")
        try fileManager.createDirectory(at: ollama, withIntermediateDirectories: true)
        let logs = ollama.appendingPathComponent("logs")
        try fileManager.createSymbolicLink(at: logs, withDestinationURL: foreign)

        let lmstudio = fixtureHome.appendingPathComponent(".lmstudio")
        try createData(at: "foreign-studio/server-logs")
        try fileManager.createSymbolicLink(at: lmstudio, withDestinationURL: fixtureHome.appendingPathComponent("foreign-studio"))
        let linkedLogs = lmstudio.appendingPathComponent("server-logs")

        let result = await CleaningEngine(homeDirectory: fixtureHome)
            .cleanItems([item(at: logs.path), item(at: linkedLogs.path)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(fileManager.fileExists(atPath: foreign.appendingPathComponent("data.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixtureHome.appendingPathComponent("foreign-studio/server-logs/data.bin").path))
    }

    func testAIAppCleanupRejectsVirtualActionsAndUnnormalizedPaths() async throws {
        try createData(at: ".ollama/logs")
        let logs = fixtureHome.appendingPathComponent(".ollama/logs").path
        let paths = [
            CleanableItem.simctlRuntimePathPrefix + UUID().uuidString,
            "", logs + "\0", fixtureHome.path + "/.ollama/../.ollama/logs",
        ]

        let result = await CleaningEngine(homeDirectory: fixtureHome).cleanItems(paths.map { item(at: $0) }) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, paths.count)
        XCTAssertTrue(fileManager.fileExists(atPath: logs))
    }

    func testAIAppCleanupNeverUsesAdministratorRemoval() async throws {
        try createData(at: ".ollama/logs")
        let logs = fixtureHome.appendingPathComponent(".ollama/logs").path

        let result = await CleaningEngine(homeDirectory: fixtureHome)
            .cleanWithAdminPrivileges(items: [item(at: logs)])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: logs))
    }

    func testAIAppPermissionFailureDoesNotRequestAdministratorRemoval() async throws {
        try createData(at: ".ollama/logs")
        let logs = fixtureHome.appendingPathComponent(".ollama/logs")
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: logs.path)
        defer {
            do {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
            } catch {
                XCTFail("Could not restore fixture permissions: \(error)")
            }
        }

        let result = await CleaningEngine(homeDirectory: fixtureHome)
            .cleanItems([item(at: logs.path)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        XCTAssertEqual(result.errors, ["AI app cleanup requires access as the current user: \(logs.path)"])
        XCTAssertTrue(fileManager.fileExists(atPath: logs.appendingPathComponent("data.bin").path))
    }

    private func createData(at relativePath: String, directory: Bool = true) throws {
        let url = fixtureHome.appendingPathComponent(relativePath)
        let file = directory ? url.appendingPathComponent("data.bin") : url
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096).write(to: file)
    }

    private func item(at path: String) -> CleanableItem {
        CleanableItem(name: "AI app data", path: path, size: 4096, category: .aiApps, isSelected: true, lastModified: nil)
    }
}
