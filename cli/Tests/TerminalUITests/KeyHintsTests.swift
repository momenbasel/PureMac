import XCTest
@testable import TerminalUI

final class KeyHintsTests: XCTestCase {
    private let menu = KeyHints([
        KeyHint("↑↓", "move"),
        KeyHint("PgUp/PgDn", "page"),
        KeyHint("1-9", "open"),
        KeyHint("Enter", "open"),
        KeyHint("Esc/q", "cancel")
    ])

    private func text(_ rows: [[Span]]) -> [String] {
        rows.map { $0.map(\.text).joined() }
    }

    func testNoHintsNoRows() {
        XCTAssertEqual(KeyHints([]).rows(width: 40), [])
    }

    func testWrapsAtThirtySixColumns() {
        XCTAssertEqual(text(menu.rows(width: 36)), [
            "↑↓ move  PgUp/PgDn page  1-9 open",
            "Enter open  Esc/q cancel"
        ])
    }

    func testStaysOnOneRowAtSeventySixColumns() {
        XCTAssertEqual(text(menu.rows(width: 76)), ["↑↓ move  PgUp/PgDn page  1-9 open  Enter open  Esc/q cancel"])
    }

    func testRowFitsExactly() {
        XCTAssertEqual(text(KeyHints([KeyHint("a", "b"), KeyHint("c", "d")]).rows(width: 8)), ["a b  c d"])
        XCTAssertEqual(text(KeyHints([KeyHint("a", "b"), KeyHint("c", "d")]).rows(width: 7)), ["a b", "c d"])
    }

    func testHintWiderThanWidthSitsAlone() {
        let hints = KeyHints([KeyHint("Enter", "open"), KeyHint("q", "x"), KeyHint("w", "y")])
        XCTAssertEqual(text(hints.rows(width: 5)), ["Enter open", "q x", "w y"])
    }

    func testKeyIsPlainAndActionIsDim() {
        let row = KeyHints([KeyHint("a", "b"), KeyHint("c", "d")]).rows(width: 20)[0]
        XCTAssertEqual(row, [
            Span("a"), Span(" b", TextStyle(dim: true)),
            Span("  "),
            Span("c"), Span(" d", TextStyle(dim: true))
        ])
    }

    func testRenderWritesRowsIntoRect() {
        var buffer = Buffer(width: 12, height: 5)
        KeyHints([KeyHint("a", "b"), KeyHint("c", "d"), KeyHint("e", "f")])
            .render(in: Rect(x: 2, y: 1, width: 8, height: 2), buffer: &buffer)
        XCTAssertEqual(buffer.plainLines(), [
            "            ",
            "  a b  c d  ",
            "  e f       ",
            "            ",
            "            "
        ])
        XCTAssertEqual(buffer[2, 1].style, .plain)
        XCTAssertEqual(buffer[3, 1].style, TextStyle(dim: true))
    }

    func testRenderDropsRowsBeyondRectHeightAndClipsWidth() {
        var buffer = Buffer(width: 10, height: 4)
        KeyHints([KeyHint("Enter", "open"), KeyHint("q", "x"), KeyHint("w", "y")])
            .render(in: Rect(x: 0, y: 0, width: 5, height: 2), buffer: &buffer)
        XCTAssertEqual(buffer.plainLines()[0], "Enter     ")
        XCTAssertEqual(buffer.plainLines()[1], "q x       ")
        XCTAssertEqual(buffer.plainLines()[2], "          ")
    }
}
