import XCTest
@testable import TerminalUI

final class TermTests: XCTestCase {
    func testANSIAndUnicodeDisplayWidth() {
        XCTAssertEqual(Term.displayWidth("\u{1B}[31mclean\u{1B}[0m"), 5)
        XCTAssertEqual(Term.displayWidth("界"), 2)
        XCTAssertEqual(Term.displayWidth("a\u{301}"), 1)
    }

    func testSpanWidthSumsSanitizedText() {
        XCTAssertEqual(Term.displayWidth([Span("ab"), Span("界")]), 4)
        XCTAssertEqual(Term.displayWidth([Span("a\u{1B}[2Jb")]), 6)
        XCTAssertEqual(Term.displayWidth([Span]()), 0)
    }

    func testTerminalControlCharactersAreSanitized() {
        XCTAssertEqual(Term.sanitize("safe\u{1B}[2Jname\n"), "safe�[2Jname�")
        XCTAssertEqual(Term.sanitize("one\ttwo"), "one two")
    }

    func testMiddleTruncationRespectsVisibleWidth() {
        let value = Term.truncate("/Users/example/Library/Caches/tool", to: 18, middle: true)
        XCTAssertLessThanOrEqual(Term.displayWidth(value), 18)
        XCTAssertTrue(value.contains("…"))
        XCTAssertTrue(value.hasPrefix("/Users/e"))
        XCTAssertTrue(value.hasSuffix("ches/tool"))
    }

    func testWrapPreservesEveryCharacter() {
        let path = "/Users/example/a folder/with/a/very-long-name/file.bin"
        let lines = Term.wrap(path, width: 11)

        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(), path)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 11 })
    }

    func testWordWrapKeepsSpaceRunsWithinALine() {
        XCTAssertEqual(Term.wordWrap("one   two  three", width: 12), ["one   two", "three"])
        XCTAssertEqual(Term.wordWrap("1 skipped  protected or ignored", width: 40), ["1 skipped  protected or ignored"])
    }

    func testWordWrapDropsSpaceRunAtALineBreak() {
        XCTAssertEqual(Term.wordWrap("one   two  three", width: 7), ["one", "two", "three"])
    }

    func testBalancedWrapKeepsLineCountAndEvensTheLines() {
        let text = "Searching 1 folder for build artifacts can take a few minutes."
        XCTAssertEqual(Term.wordWrap(text, width: 54), ["Searching 1 folder for build artifacts can take a few", "minutes."])
        XCTAssertEqual(Term.balancedWrap(text, width: 54), ["Searching 1 folder for build", "artifacts can take a few minutes."])
        XCTAssertEqual(Term.balancedWrap(text, width: 30), ["Searching 1 folder for", "build artifacts can", "take a few minutes."])
    }

    func testBalancedWrapLeavesShortTextAndHardBreaksAlone() {
        XCTAssertEqual(Term.balancedWrap("one two", width: 20), ["one two"])
        XCTAssertEqual(Term.balancedWrap("", width: 10), [""])
        XCTAssertEqual(Term.balancedWrap("ab abcdefg", width: 3), ["ab", "abc", "def", "g"])
    }

    func testBalancedWrapNeverBreaksAWordThatGreedyWrapKeptWhole() {
        XCTAssertEqual(Term.balancedWrap("aaaa b", width: 5), ["aaaa", "b"])
    }

    func testWordWrapEmptyParagraphIsOneEmptyRow() {
        XCTAssertEqual(Term.wordWrap("", width: 10), [""])
    }

    func testWordWrapHardBreaksLongWord() {
        XCTAssertEqual(Term.wordWrap("ab abcdefg", width: 3), ["ab", "abc", "def", "g"])
    }

    func testSpanWordWrapKeepsStylesAcrossLines() {
        let dim = TextStyle(dim: true)
        let cyan = TextStyle(color: .cyan)
        let spans = [Span("Add one with ", dim), Span("`puremac ignore add <path>`", cyan), Span(".", dim)]
        XCTAssertEqual(Term.wordWrap(spans, width: 24), [
            [Span("Add one with ", dim), Span("`puremac", cyan)],
            [Span("ignore add <path>`", cyan), Span(".", dim)],
        ])
    }

    func testSpanWordWrapDropsTheSpaceAtALineBreakWhateverItsStyle() {
        let dim = TextStyle(dim: true)
        XCTAssertEqual(
            Term.wordWrap([Span("one ", dim), Span("two", .plain)], width: 3),
            [[Span("one", dim)], [Span("two")]]
        )
    }

    func testSpanWordWrapJoinsAWordSplitAcrossSpans() {
        let bold = TextStyle(bold: true)
        XCTAssertEqual(
            Term.wordWrap([Span("ab", bold), Span("cd ef")], width: 5),
            [[Span("ab", bold), Span("cd")], [Span("ef")]]
        )
    }

    func testSpanWordWrapHardBreaksALongWordKeepingItsStyle() {
        let cyan = TextStyle(color: .cyan)
        XCTAssertEqual(
            Term.wordWrap([Span("ab ", .plain), Span("abcdefg", cyan)], width: 3),
            [[Span("ab")], [Span("abc", cyan)], [Span("def", cyan)], [Span("g", cyan)]]
        )
    }

    func testSpanWordWrapOfNothingIsOneEmptyRow() {
        XCTAssertEqual(Term.wordWrap([Span("")], width: 10), [[]])
        XCTAssertEqual(Term.wordWrap([], width: 10), [[]])
    }

    func testStyledJoinsSpanTextAndAddsCodesOnlyWithColors() {
        let dim = TextStyle(dim: true)
        let spans = [Span("a", dim), Span("b", dim), Span("c")]
        XCTAssertEqual(Term.styled(spans, colors: false), "abc")
        XCTAssertEqual(Term.styled(spans, colors: true), "\u{1B}[0m\u{1B}[2mab\u{1B}[0mc")
        XCTAssertEqual(Term.styled([], colors: true), "")
    }

    func testStyledKeepsZeroWidthCharactersAndSanitizesControls() {
        XCTAssertEqual(Term.styled([Span("a\u{200B}b\u{07}")], colors: false), "a\u{200B}b\u{FFFD}")
    }
}
