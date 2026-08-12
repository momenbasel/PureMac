import XCTest
@testable import PureMac

final class VSCodeExtensionLeftoverFinderTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacExtLeft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
    }

    func testFindsInstallGlobalWorkspaceAndVsixCache() throws {
        let install = try makeInstall(
            dot: ".cursor",
            folder: "ms-python.python-2025.1.0",
            extensionId: "ms-python.python",
            displayName: "Python"
        )
        let support = tempHome.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        let global = support.appendingPathComponent("User/globalStorage/ms-python.python", isDirectory: true)
        let workspaceChild = support.appendingPathComponent(
            "User/workspaceStorage/abc123/ms-python.python",
            isDirectory: true
        )
        let vsix = support.appendingPathComponent(
            "CachedExtensionVSIXs/ms-python.python-2025.1.0-darwin-arm64",
            isDirectory: true
        )
        let other = support.appendingPathComponent("User/globalStorage/redhat.java", isDirectory: true)
        for url in [global, workspaceChild, vsix, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let item = VSCodeExtensionItem(
            editorLabel: "Cursor",
            displayName: "Python",
            path: install.path,
            size: 1,
            lastModified: nil,
            extensionId: "ms-python.python",
            editorDotDirectory: ".cursor"
        )
        let urls = VSCodeExtensionLeftoverFinder.findRelatedPaths(for: item, homeDirectory: tempHome)
        let paths = Set(urls.map { ($0.path as NSString).standardizingPath })

        XCTAssertTrue(paths.contains((install.path as NSString).standardizingPath))
        XCTAssertTrue(paths.contains((global.path as NSString).standardizingPath))
        XCTAssertTrue(paths.contains((workspaceChild.path as NSString).standardizingPath))
        XCTAssertTrue(paths.contains((vsix.path as NSString).standardizingPath))
        XCTAssertFalse(paths.contains((other.path as NSString).standardizingPath))
    }

    func testSafetyAllowsIdChildButNotWorkspaceHashRoot() throws {
        let home = tempHome.path
        let hashRoot = "\(home)/Library/Application Support/Cursor/User/workspaceStorage/abc123"
        let idChild = "\(hashRoot)/ms-python.python"
        let global = "\(home)/Library/Application Support/Cursor/User/globalStorage/ms-python.python"

        XCTAssertTrue(
            VSCodeExtensionLeftoverFinder.isSafeRelatedPath(
                idChild,
                extensionId: "ms-python.python",
                homeDirectoryPath: home
            )
        )
        XCTAssertTrue(
            VSCodeExtensionLeftoverFinder.isSafeRelatedPath(
                global,
                extensionId: "ms-python.python",
                homeDirectoryPath: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionLeftoverFinder.isSafeRelatedPath(
                hashRoot,
                extensionId: "ms-python.python",
                homeDirectoryPath: home
            )
        )
    }

    func testFindsHomePersonalizationDotDir() throws {
        let install = try makeInstall(
            dot: ".cursor",
            folder: "Continue.continue-1.0.0",
            extensionId: "Continue.continue",
            displayName: "Continue"
        )
        let personal = tempHome.appendingPathComponent(".continue", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let unrelated = tempHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let item = VSCodeExtensionItem(
            editorLabel: "Cursor",
            displayName: "Continue",
            path: install.path,
            size: 1,
            lastModified: nil,
            extensionId: "Continue.continue",
            editorDotDirectory: ".cursor"
        )
        let urls = VSCodeExtensionLeftoverFinder.findRelatedPaths(for: item, homeDirectory: tempHome)
        let paths = Set(urls.map { ($0.path as NSString).standardizingPath })
        XCTAssertTrue(paths.contains((personal.path as NSString).standardizingPath))
        XCTAssertFalse(paths.contains((unrelated.path as NSString).standardizingPath))

        XCTAssertTrue(
            VSCodeExtensionLeftoverFinder.isSafeRelatedPath(
                personal.path,
                extensionId: "Continue.continue",
                homeDirectoryPath: tempHome.path
            )
        )
        let selected = VSCodeExtensionHomePathRules.defaultSelectedPaths(from: urls, homeDirectory: tempHome)
        XCTAssertFalse(selected.contains(where: {
            ($0.path as NSString).standardizingPath == (personal.path as NSString).standardizingPath
        }))

        // Path-only CleaningEngine entry must not allow bare ~/.continue.
        XCTAssertFalse(
            VSCodeExtensionLeftoverFinder.isSafeRelatedPath(
                personal.path,
                homeDirectoryPath: tempHome.path
            )
        )
    }

    private func makeInstall(
        dot: String,
        folder: String,
        extensionId: String,
        displayName: String
    ) throws -> URL {
        let parts = extensionId.split(separator: ".")
        let publisher = String(parts[0])
        let name = String(parts[1])
        let ext = tempHome
            .appendingPathComponent(dot, isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        let pkg: [String: Any] = [
            "name": name,
            "publisher": publisher,
            "displayName": displayName,
            "version": "1.0.0",
            "engines": ["vscode": "^1.60.0"],
        ]
        try JSONSerialization.data(withJSONObject: pkg)
            .write(to: ext.appendingPathComponent("package.json"))
        return ext
    }
}
