import XCTest
@testable import PureMac

final class VSCodeExtensionScannerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacVSExt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
    }

    func testDiscoversUnknownEditorRootWithoutHardcodedList() throws {
        let ext = try makeExtension(
            under: ".totally-new-fork/extensions",
            folder: "pub.sample-1.0.0",
            displayName: "Sample",
            fileBytes: 8,
            enginesVSCode: "^1.80.0"
        )

        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].editorLabel, "Totally New Fork")
        XCTAssertEqual(items[0].displayName, "Sample")
        XCTAssertEqual(items[0].path, (ext.path as NSString).standardizingPath)
    }

    func testSkipsExtensionFoldersWithoutEnginesVSCode() throws {
        try makeExtension(
            under: ".openclaw/extensions",
            folder: "agent.plugin-1.0.0",
            displayName: "Agent Plugin",
            fileBytes: 8,
            enginesVSCode: nil
        )
        try makeExtension(
            under: ".cursor/extensions",
            folder: "pub.real-1.0.0",
            displayName: "Real",
            fileBytes: 8,
            enginesVSCode: "^1.70.0"
        )

        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)

        XCTAssertEqual(items.map(\.displayName), ["Real"])
        XCTAssertEqual(items.map(\.editorLabel), ["Cursor"])
    }

    func testScanFindsExtensionWithPackageJSON() throws {
        let extDir = try makeExtension(
            under: ".cursor/extensions",
            folder: "aaron-bond.better-comments-3.0.2-universal",
            displayName: "Better Comments",
            fileBytes: 64,
            enginesVSCode: "^1.60.0"
        )

        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].editorLabel, "Cursor")
        XCTAssertEqual(items[0].displayName, "Better Comments")
        XCTAssertEqual(items[0].path, (extDir.path as NSString).standardizingPath)
        XCTAssertGreaterThan(items[0].size, 0)
        XCTAssertEqual(items[0].listName, "Cursor · Better Comments")
    }

    func testScanSkipsHiddenAndMissingPackageJSON() throws {
        try makeExtension(
            under: ".vscode/extensions",
            folder: "pub.good-1.0.0",
            displayName: "Good",
            fileBytes: 8,
            enginesVSCode: "^1.60.0"
        )
        let hidden = tempHome.appendingPathComponent(".vscode/extensions/.obsolete", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let noPkg = tempHome.appendingPathComponent(".vscode/extensions/broken-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: noPkg, withIntermediateDirectories: true)

        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)

        XCTAssertEqual(items.map(\.displayName), ["Good"])
    }

    func testScanMissingRootIsEmpty() {
        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)
        XCTAssertTrue(items.isEmpty)
    }

    func testItemsSortedBySizeDescending() throws {
        try makeExtension(
            under: ".vscode/extensions",
            folder: "a.small-1.0.0",
            displayName: "Small",
            fileBytes: 16,
            enginesVSCode: "^1.60.0"
        )
        try makeExtension(
            under: ".vscode/extensions",
            folder: "b.large-1.0.0",
            displayName: "Large",
            fileBytes: 4096,
            enginesVSCode: "^1.60.0"
        )

        let items = VSCodeExtensionScanner.scan(homeDirectory: tempHome)

        XCTAssertEqual(items.map(\.displayName), ["Large", "Small"])
    }

    func testScanCategoryMapsExtensionsAsUnselectedCleanableItems() throws {
        let ext = try makeExtension(
            under: ".vscode/extensions",
            folder: "pub.demo-1.0.0",
            displayName: "Demo Ext",
            fileBytes: 32,
            enginesVSCode: "^1.60.0"
        )
        let discovered = VSCodeExtensionScanner.scan(homeDirectory: tempHome)
        XCTAssertEqual(discovered.count, 1)
        let item = CleanableItem(
            name: discovered[0].listName,
            path: discovered[0].path,
            size: discovered[0].size,
            category: .vsCodeExtensions,
            isSelected: false,
            lastModified: discovered[0].lastModified
        )
        XCTAssertFalse(item.isSelected)
        XCTAssertEqual(item.name, "Vscode · Demo Ext")
        XCTAssertEqual(item.path, (ext.path as NSString).standardizingPath)
        XCTAssertEqual(item.category, .vsCodeExtensions)
    }

    func testIsSafeDeletePathRequiresVSCodeEngineManifest() throws {
        let home = tempHome.path
        let ok = try makeExtension(
            under: ".cursor/extensions",
            folder: "pub.name-1.0.0",
            displayName: "Name",
            fileBytes: 4,
            enginesVSCode: "^1.60.0"
        )
        let noEngine = try makeExtension(
            under: ".openclaw/extensions",
            folder: "agent.plug-1.0.0",
            displayName: "Plug",
            fileBytes: 4,
            enginesVSCode: nil
        )

        XCTAssertTrue(VSCodeExtensionScanner.isSafeDeletePath(ok.path, homeDirectoryPath: home))
        XCTAssertFalse(VSCodeExtensionScanner.isSafeDeletePath(noEngine.path, homeDirectoryPath: home))
        XCTAssertFalse(
            VSCodeExtensionScanner.isSafeDeletePath(
                "\(home)/.cursor/extensions",
                homeDirectoryPath: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionScanner.isSafeDeletePath("\(home)/.cursor", homeDirectoryPath: home)
        )
        XCTAssertFalse(
            VSCodeExtensionScanner.isSafeDeletePath(
                "\(home)/.cursor/argv.json",
                homeDirectoryPath: home
            )
        )
        XCTAssertFalse(
            VSCodeExtensionScanner.isSafeDeletePath(
                "\(home)/.cursor/extensions_backup/x",
                homeDirectoryPath: home
            )
        )
    }

    @discardableResult
    private func makeExtension(
        under relativeRoot: String,
        folder: String,
        displayName: String,
        fileBytes: Int,
        enginesVSCode: String?
    ) throws -> URL {
        let root = tempHome.appendingPathComponent(relativeRoot, isDirectory: true)
        let ext = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        var pkg: [String: Any] = [
            "name": "ext",
            "displayName": displayName,
            "publisher": "pub",
            "version": "1.0.0",
        ]
        if let enginesVSCode {
            pkg["engines"] = ["vscode": enginesVSCode]
        }
        let data = try JSONSerialization.data(withJSONObject: pkg)
        try data.write(to: ext.appendingPathComponent("package.json"))
        let blob = Data(repeating: 0x61, count: fileBytes)
        try blob.write(to: ext.appendingPathComponent("payload.bin"))
        return ext
    }
}
