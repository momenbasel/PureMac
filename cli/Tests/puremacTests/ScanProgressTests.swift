import Foundation
import XCTest
@testable import puremac

final class ScanProgressTests: XCTestCase {
    func testFullscreenCleanupWritesNoScanProgress() {
        XCTAssertEqual(ScanProgress.forMode(.fullscreen), .silent)
        for mode in [CleanupCommandMode.plain, .forced, .reportOnly] {
            XCTAssertEqual(ScanProgress.forMode(mode), .stderr)
        }
    }

    func testSilentScanWritesNothingToStderrAndDefaultKeepsTheProgressLine() throws {
        let silent = try captureStderr { _ = CategoryScanner.scan(categoryID: "none", title: "None", ignore: ignore(), progress: .silent) }
        XCTAssertEqual(silent, "")
        let verbose = try captureStderr { _ = CategoryScanner.scan(categoryID: "none", title: "None", ignore: ignore()) }
        XCTAssertTrue(verbose.hasPrefix("  scanning None…\r"))
    }

    func testDefaultScanOfAnUnknownCategoryIsEmpty() {
        let scan = CategoryScanner.scan(categoryID: "none", title: "None", ignore: ignore(), progress: .silent)
        XCTAssertEqual(scan.id, "none")
        XCTAssertEqual(scan.title, "None")
        XCTAssertTrue(scan.groups.isEmpty)
    }

    private func ignore() -> IgnoreStore {
        try! IgnoreStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("scan-progress-\(UUID().uuidString)"))
    }
}
