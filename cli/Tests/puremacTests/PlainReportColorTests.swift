import XCTest
@testable import puremac
import TerminalUI

final class PlainReportColorTests: XCTestCase {
    private let small = ScanItem(path: "/tmp/a/small", sizeBytes: 50_000_000, modified: nil)
    private let medium = ScanItem(path: "/tmp/a/medium", sizeBytes: 150_000_000, modified: nil, selected: false)
    private let large = ScanItem(path: "/tmp/a/large", sizeBytes: 2_000_000_000, modified: nil)

    private var categories: [CategoryScan] {
        [CategoryScan(id: "c", title: "Caches", groups: [ToolGroup(tool: "Xcode", items: [small, medium, large])])]
    }

    private func colored(_ bytes: Int64, _ code: Int) -> String {
        "\u{1B}[0m\u{1B}[\(code)m\(Render.sizeCol(bytes))\u{1B}[0m"
    }

    private func stripped(_ colored: String) -> String {
        colored.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func assertSameTextWithColors(_ plain: String, _ output: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(output, plain, file: file, line: line)
        XCTAssertEqual(stripped(output), plain, file: file, line: line)
    }

    func testScanResultsPlainTextIsPinned() throws {
        let output = try captureStdout { Render.scanResults(categories, colors: false) }
        XCTAssertEqual(output, """

        Scan complete
        2.2 GB across 3 items

        Caches  2.2 GB
          Xcode  3 items
            ● 50 MB      /tmp/a/small
            ○ 150 MB     /tmp/a/medium
            ● 2 GB       /tmp/a/large

        """)
    }

    func testDeletionReviewPlainTextIsPinned() throws {
        let output = try captureStdout { Render.deletionReview(categories, colors: false) }
        XCTAssertEqual(output, """

        Permanent deletion review
        ────────────────────────────────────────────────────────────────────────
        Caches  2 GB
          50 MB      Xcode
            /tmp/a/small
          2 GB       Xcode
            /tmp/a/large
        ────────────────────────────────────────────────────────────────────────
        2 GB  2 items

        """)
    }

    func testPurgeRenderScanPlainTextIsPinned() throws {
        let output = try captureStdout { Purge().renderScan(categories[0], days: 7, colors: false) }
        XCTAssertEqual(output, """

        Found 2.2 GB across 1 project

          Xcode  2.2 GB
            ✓ 50 MB      /tmp/a/small
            · 150 MB     /tmp/a/medium  recent
            ✓ 2 GB       /tmp/a/large

        Artifacts newer than 7 days are shown but left unchecked.

        """)
    }

    func testAnalyzePrintLevelPlainTextIsPinned() throws {
        let children = [
            Analyze.Child(path: "/tmp/a/big", size: 300_000_000, isDir: false, isPackage: false, inaccessibleCount: 0, skippedCount: 0),
            Analyze.Child(path: "/tmp/a/dir", size: 100_000_000, isDir: false, isPackage: false, inaccessibleCount: 1, skippedCount: 0)
        ]
        let output = try captureStdout { Analyze().printLevel(children, total: 400_000_000, indent: "  ", depthLeft: 0, colors: false) }
        XCTAssertEqual(output, """
          300 MB      75.0% ███████████████░░░░░ big
          100 MB      25.0% █████░░░░░░░░░░░░░░░ dir !

        """)
    }

    func testScanResultsColorsSizesAndStylesWithTheFlag() throws {
        let plain = try captureStdout { Render.scanResults(categories, colors: false) }
        let output = try captureStdout { Render.scanResults(categories, colors: true) }
        assertSameTextWithColors(plain, output)
        XCTAssertTrue(output.contains(colored(2_000_000_000, 31)))
        XCTAssertTrue(output.contains("\u{1B}[0m\u{1B}[1mScan complete\u{1B}[0m"))
    }

    func testDeletionReviewColorsSizesAndStylesWithTheFlag() throws {
        let plain = try captureStdout { Render.deletionReview(categories, colors: false) }
        let output = try captureStdout { Render.deletionReview(categories, colors: true) }
        assertSameTextWithColors(plain, output)
        XCTAssertTrue(output.contains(colored(50_000_000, 32)))
        XCTAssertFalse(output.contains(colored(150_000_000, 33)))
    }

    func testPurgeRenderScanColorsSizesAndStylesWithTheFlag() throws {
        let plain = try captureStdout { Purge().renderScan(categories[0], days: 7, colors: false) }
        let output = try captureStdout { Purge().renderScan(categories[0], days: 7, colors: true) }
        assertSameTextWithColors(plain, output)
        XCTAssertTrue(output.contains(colored(150_000_000, 33)))
    }

    func testPrintLevelColorsSizeAndFilledBar() throws {
        let child = Analyze.Child(path: "/tmp/a/big", size: 300_000_000, isDir: false, isPackage: false, inaccessibleCount: 0, skippedCount: 0)
        let output = try captureStdout { Analyze().printLevel([child], total: 400_000_000, indent: "  ", depthLeft: 0, colors: true) }
        let size = "\u{1B}[0m\u{1B}[33m300 MB    \u{1B}[0m"
        let bar = "\u{1B}[0m\u{1B}[33m" + String(repeating: "█", count: 15) + "\u{1B}[0m\u{1B}[2m" + String(repeating: "░", count: 5) + "\u{1B}[0m"
        let percentage = "\u{1B}[0m\u{1B}[2m 75.0%\u{1B}[0m"
        XCTAssertEqual(output, "  \(size) \(percentage) \(bar) big\n")
    }
}
