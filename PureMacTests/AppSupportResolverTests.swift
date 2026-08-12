import XCTest
@testable import PureMac

final class AppSupportResolverTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMacAS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
    }

    func testResolvesCursorAndHyphenatedTraeCN() throws {
        let support = tempHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        for name in ["Cursor", "Trae CN", "Code", "Qoder"] {
            try FileManager.default.createDirectory(
                at: support.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let cursor = AppSupportResolver.resolve(
            editorDotDirectory: ".cursor",
            homeDirectory: tempHome
        ).map(\.lastPathComponent)
        let traeCN = AppSupportResolver.resolve(
            editorDotDirectory: ".trae-cn",
            homeDirectory: tempHome
        ).map(\.lastPathComponent)
        let vscode = AppSupportResolver.resolve(
            editorDotDirectory: ".vscode",
            homeDirectory: tempHome
        ).map(\.lastPathComponent)

        XCTAssertEqual(cursor, ["Cursor"])
        XCTAssertTrue(traeCN.contains("Trae CN"))
        XCTAssertEqual(vscode, ["Code"])
    }
}
