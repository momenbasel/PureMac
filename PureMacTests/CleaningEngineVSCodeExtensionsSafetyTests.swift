import XCTest
@testable import PureMac

final class CleaningEngineVSCodeExtensionsSafetyTests: XCTestCase {
    func testCleaningEngineAllowListAcceptsVSCodeEngineExtensionOnly() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extensionsRoot = home.appendingPathComponent(".cursor/extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionsRoot, withIntermediateDirectories: true)

        let probe = extensionsRoot.appendingPathComponent(
            "puremac.safety-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }

        let pkg: [String: Any] = [
            "name": "puremac-safety-probe",
            "displayName": "PureMac Safety Probe",
            "engines": ["vscode": "^1.60.0"],
        ]
        try JSONSerialization.data(withJSONObject: pkg)
            .write(to: probe.appendingPathComponent("package.json"))

        let engine = CleaningEngine()
        let allowed = await engine.isAllowedCleanupPath(probe.path)
        let rootAllowed = await engine.isAllowedCleanupPath(extensionsRoot.path)
        let editorHomeBlocked = await engine.isAllowedCleanupPath(home.appendingPathComponent(".cursor").path)
        let settingsBlocked = await engine.isAllowedCleanupPath(
            home.appendingPathComponent(".cursor/argv.json").path
        )
        let siblingBlocked = await engine.isAllowedCleanupPath(
            home.appendingPathComponent(".cursor/extensions_backup/x").path
        )

        XCTAssertTrue(allowed, "VS Code engine extension under ~/.*/extensions must be allow-listed")
        XCTAssertFalse(rootAllowed, "entire extensions root must not be deletable")
        XCTAssertFalse(editorHomeBlocked, "~/.cursor must not be deletable")
        XCTAssertFalse(settingsBlocked, "editor settings must not be deletable")
        XCTAssertFalse(siblingBlocked, "sibling of extensions/ must not sneak past prefix match")
    }

    func testScanEngineEmitsUnselectedVSCodeExtensionItems() async throws {
        let engine = ScanEngine()
        let result = await engine.scanCategory(.vsCodeExtensions)
        XCTAssertEqual(result.category, .vsCodeExtensions)
        if !result.items.isEmpty {
            XCTAssertTrue(result.items.allSatisfy { !$0.isSelected })
            XCTAssertTrue(result.items.allSatisfy { !$0.path.isEmpty })
            XCTAssertGreaterThan(result.totalSize, 0)
            XCTAssertTrue(result.items.contains { $0.name.contains(" · ") })
        }
    }
}
