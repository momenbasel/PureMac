import XCTest
@testable import puremac
import TerminalUI

final class StatusScreenTests: XCTestCase {
    private let hint = StatusScreen.scanHint
    private let hintText = "\(StatusScreen.scanHint.key) \(StatusScreen.scanHint.action)"

    func testRendersWindowRowsDividerAndHint() {
        let buffer = StatusScreen.render(
            title: "PureMac",
            rows: [
                StatusRow("Working...", style: TextStyle(dim: true)),
                StatusRow("/Users/example/" + String(repeating: "a", count: 60), truncatesInMiddle: true)
            ],
            hint: hint,
            width: 40,
            height: 12
        )
        let lines = buffer.plainLines()
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines[0].hasPrefix("╭─ PureMac "))
        XCTAssertTrue(lines[1].contains("Working..."))
        XCTAssertTrue(lines[2].contains("…"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("├") && $0.hasSuffix("┤") })
        XCTAssertTrue(lines.contains { $0.contains(hintText) })
        XCTAssertTrue(buffer[2, 1].style.dim)
    }

    func testLongMessageEndsWithEllipsis() {
        let message = "Scanning ~/Projects, ~/Code, ~/dev, ~/GitHub, ~/Workspace …"
        let lines = StatusScreen.render(
            title: "PureMac", rows: [StatusRow(message, style: TextStyle(dim: true)), StatusRow("")], hint: hint, width: 40, height: 12
        ).plainLines()
        XCTAssertTrue(lines[1].contains("… │"), lines[1])
        XCTAssertFalse(lines[1].contains("Workspace"))
    }

    func testRowsAfterTheLastOneStayBlank() {
        let lines = StatusScreen.render(
            title: "PureMac", rows: [StatusRow("Working...", style: TextStyle(dim: true))], hint: hint, width: 40, height: 12
        ).plainLines()
        XCTAssertEqual(lines[2], "│" + String(repeating: " ", count: 38) + "│")
    }

    func testBelowMinimumUsesTooSmallScreenWithHintAsExit() {
        XCTAssertEqual(
            StatusScreen.render(title: "PureMac", rows: [StatusRow("x", style: TextStyle(dim: true)), StatusRow("")], hint: hint, width: 39, height: 11),
            TooSmallScreen.render(title: "PureMac", exitHint: hintText, width: 39, height: 11)
        )
    }

    func testOverlayFadesBackgroundAndCentersDialog() {
        let background = StatusScreen.render(
            title: "PureMac", rows: [StatusRow("Working...", style: TextStyle(dim: true)), StatusRow("")], hint: hint, width: 60, height: 14
        )
        let dialog = Dialog(title: "Done", message: [Span("All good.")])
        let result = StatusScreen.overlay(dialog, on: background)
        XCTAssertEqual(result[0, 0].style, TextStyle(dim: true))
        XCTAssertTrue(result.plainLines().contains { $0.contains("All good.") })
        XCTAssertTrue(result.plainLines().contains { $0.contains(hintText) })
    }

    func testOverlayLeavesTooSmallBackgroundUntouched() {
        let background = TooSmallScreen.render(title: "PureMac", exitHint: hintText, width: 30, height: 8)
        let result = StatusScreen.overlay(Dialog(title: "Done", message: [Span("All good.")]), on: background)
        XCTAssertEqual(result, background)
    }

    func testRowsRenderWithTheirOwnStyleAndTruncation() {
        let long = "/Users/example/" + String(repeating: "a", count: 60) + "/end"
        let buffer = StatusScreen.render(
            title: "PureMac",
            rows: [
                StatusRow("First", style: TextStyle(dim: true)),
                StatusRow(long, truncatesInMiddle: true),
                StatusRow("Third")
            ],
            hint: hint,
            width: 40,
            height: 12
        )
        let lines = buffer.plainLines()
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines[1].contains("First"))
        XCTAssertTrue(buffer[2, 1].style.dim)
        XCTAssertTrue(lines[2].contains("…") && lines[2].contains("/end"))
        XCTAssertFalse(buffer[2, 2].style.dim)
        XCTAssertTrue(lines[3].contains("Third"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("├") })
        XCTAssertTrue(lines.contains { $0.contains(hintText) })
    }
}
