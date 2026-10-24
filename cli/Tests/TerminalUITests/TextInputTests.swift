import XCTest
@testable import TerminalUI

final class TextInputTests: XCTestCase {
    func testInsertAppendsAtTheEnd() {
        var input = TextInput("ab")
        input.insert("c")
        XCTAssertEqual(input.text, "abc")
    }

    func testBackspaceDropsTheLastCharacterAndIgnoresEmptyText() {
        var input = TextInput("ab")
        input.backspace()
        XCTAssertEqual(input.text, "a")
        input.backspace()
        input.backspace()
        XCTAssertEqual(input.text, "")
        XCTAssertTrue(input.isEmpty)
    }

    func testHandleEditsOnTypingKeysAndReportsWhetherTheTextChanged() {
        var input = TextInput()
        XCTAssertTrue(input.handle(.character("a")))
        XCTAssertTrue(input.handle(.space))
        XCTAssertTrue(input.handle(.character("é")))
        XCTAssertEqual(input.text, "a é")
        XCTAssertTrue(input.handle(.backspace))
        XCTAssertTrue(input.handle(.delete))
        XCTAssertEqual(input.text, "a")
    }

    func testHandleIgnoresControlCharactersAndOtherKeys() {
        var input = TextInput("a")
        XCTAssertFalse(input.handle(.character("\u{7F}")))
        XCTAssertFalse(input.handle(.character("\n")))
        for key in [TerminalKey.up, .down, .left, .right, .enter, .escape, .tab, .home, .unknown] {
            XCTAssertFalse(input.handle(key), "\(key)")
        }
        XCTAssertEqual(input.text, "a")
    }

    func testHandleReportsNoChangeForBackspaceOnEmptyText() {
        var input = TextInput()
        XCTAssertFalse(input.handle(.backspace))
    }

    func testFieldSpansShowLabelTextAndInverseCursor() {
        let spans = TextInput("sec").fieldSpans(label: "Search  ", width: 40)
        XCTAssertEqual(spans, [
            Span("Search  ", TextStyle(color: .cyan)),
            Span("sec"),
            Span(" ", TextStyle(inverse: true)),
        ])
    }

    func testFieldSpansTruncateLongTextToLeaveRoomForTheCursor() {
        let spans = TextInput(String(repeating: "x", count: 30)).fieldSpans(label: "Add  ", width: 12)
        XCTAssertEqual(Term.displayWidth(spans), 12)
        XCTAssertEqual(spans.last, Span(" ", TextStyle(inverse: true)))
    }

    func testFieldSpansKeepTheEndOfLongTextVisibleWithALeadingEllipsis() {
        let spans = TextInput("/Users/someone/projects/final-name").fieldSpans(label: "Add  ", width: 20)
        XCTAssertEqual(Term.displayWidth(spans), 20)
        XCTAssertEqual(spans[1], Span("…ts/final-name"))
    }

    func testFieldSpansCountWideLabelCharactersAsTwoColumns() {
        let spans = TextInput("abcdefghij").fieldSpans(label: "路径 ", width: 12)
        XCTAssertEqual(Term.displayWidth(spans), 12)
    }
}
