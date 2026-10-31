import XCTest
@testable import TerminalUI

final class BufferTests: XCTestCase {
    private let esc = "\u{1B}"

    func testSplitRowsLengthsAndFills() {
        let rect = Rect(x: 3, y: 2, width: 10, height: 10)
        let rows = rect.splitRows([.length(2), .fill, .length(3)])
        XCTAssertEqual(rows, [
            Rect(x: 3, y: 2, width: 10, height: 2),
            Rect(x: 3, y: 4, width: 10, height: 5),
            Rect(x: 3, y: 9, width: 10, height: 3)
        ])
    }

    func testSplitRowsFillsShareRemainderToFirst() {
        let rows = Rect(x: 0, y: 0, width: 4, height: 7).splitRows([.fill, .fill, .fill])
        XCTAssertEqual(rows.map(\.height), [3, 2, 2])
        XCTAssertEqual(rows.map(\.y), [0, 3, 5])
    }

    func testSplitRowsOverflowGivesLaterItemsNoHeight() {
        let rows = Rect(x: 0, y: 0, width: 4, height: 5).splitRows([.length(3), .length(4), .length(2), .fill])
        XCTAssertEqual(rows.map(\.height), [3, 2, 0, 0])
        XCTAssertEqual(rows.map(\.y), [0, 3, 5, 5])
    }

    func testSplitColumnsLengthsAndFills() {
        let rect = Rect(x: 3, y: 2, width: 10, height: 4)
        let columns = rect.splitColumns([.length(2), .fill, .length(3)])
        XCTAssertEqual(columns, [
            Rect(x: 3, y: 2, width: 2, height: 4),
            Rect(x: 5, y: 2, width: 5, height: 4),
            Rect(x: 10, y: 2, width: 3, height: 4)
        ])
    }

    func testSplitColumnsFillsShareRemainderToFirst() {
        let columns = Rect(x: 0, y: 0, width: 7, height: 4).splitColumns([.fill, .fill, .fill])
        XCTAssertEqual(columns.map(\.width), [3, 2, 2])
        XCTAssertEqual(columns.map(\.x), [0, 3, 5])
    }

    func testSplitColumnsOverflowGivesLaterItemsNoWidth() {
        let columns = Rect(x: 0, y: 0, width: 5, height: 4).splitColumns([.length(3), .length(4), .length(2), .fill])
        XCTAssertEqual(columns.map(\.width), [3, 2, 0, 0])
        XCTAssertEqual(columns.map(\.x), [0, 3, 5, 5])
    }

    func testNewBufferIsBlankAndClamped() {
        let buffer = Buffer(width: 3, height: 2)
        XCTAssertEqual(buffer.area, Rect(x: 0, y: 0, width: 3, height: 2))
        XCTAssertEqual(buffer.plainLines(), ["   ", "   "])
        XCTAssertEqual(buffer[1, 1], Cell(symbol: " ", style: .plain))
        let empty = Buffer(width: -4, height: -1)
        XCTAssertEqual(empty.area, Rect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(empty.plainLines(), [])
    }

    func testWriteReturnsColumnsAndPlacesText() {
        var buffer = Buffer(width: 6, height: 2)
        XCTAssertEqual(buffer.write("abc", x: 1, y: 1), 3)
        XCTAssertEqual(buffer.plainLines(), ["      ", " abc  "])
    }

    func testWriteClipsAtMaxWidthAndEdge() {
        var buffer = Buffer(width: 5, height: 1)
        XCTAssertEqual(buffer.write("abcdef", x: 0, y: 0, maxWidth: 2), 2)
        XCTAssertEqual(buffer.plainLines(), ["ab   "])
        XCTAssertEqual(buffer.write("wxyz", x: 3, y: 0), 2)
        XCTAssertEqual(buffer.plainLines(), ["ab wx"])
    }

    func testWriteOutOfRangeWritesNothing() {
        var buffer = Buffer(width: 3, height: 1)
        XCTAssertEqual(buffer.write("a", x: 3, y: 0), 0)
        XCTAssertEqual(buffer.write("a", x: -1, y: 0), 0)
        XCTAssertEqual(buffer.write("a", x: 0, y: 1), 0)
        XCTAssertEqual(buffer.write("a", x: 0, y: -1), 0)
        XCTAssertEqual(buffer.write("a", x: 0, y: 0, maxWidth: 0), 0)
        XCTAssertEqual(buffer.plainLines(), ["   "])
    }

    func testWideCharacterTakesTwoColumns() {
        var buffer = Buffer(width: 4, height: 1)
        XCTAssertEqual(buffer.write("界a", x: 0, y: 0), 3)
        XCTAssertEqual(buffer[0, 0].symbol, "界")
        XCTAssertEqual(buffer[1, 0].symbol, "")
        XCTAssertEqual(buffer.plainLines(), ["界a "])
    }

    func testWideCharacterThatDoesNotFitIsNotDrawn() {
        var buffer = Buffer(width: 3, height: 1)
        XCTAssertEqual(buffer.write("ab界", x: 0, y: 0), 2)
        XCTAssertEqual(buffer.plainLines(), ["ab "])
        XCTAssertEqual(buffer.write("界", x: 0, y: 0, maxWidth: 1), 0)
        XCTAssertEqual(buffer.plainLines(), ["ab "])
    }

    func testOverwritingEitherHalfOfWideCharacterBlanksTheOther() {
        var first = Buffer(width: 4, height: 1)
        first.write("界", x: 0, y: 0)
        first.write("x", x: 0, y: 0)
        XCTAssertEqual(first.plainLines(), ["x   "])
        XCTAssertEqual(first[1, 0], Cell(symbol: " ", style: .plain))

        var second = Buffer(width: 4, height: 1)
        second.write("界", x: 0, y: 0, style: TextStyle(bold: true))
        second.write("x", x: 1, y: 0)
        XCTAssertEqual(second.plainLines(), [" x  "])
        XCTAssertEqual(second[0, 0], Cell(symbol: " ", style: .plain))
    }

    func testOverwritingWideWithWideAcrossBoundary() {
        var buffer = Buffer(width: 6, height: 1)
        buffer.write("界界", x: 0, y: 0)
        buffer.write("界", x: 1, y: 0)
        XCTAssertEqual(buffer.plainLines(), [" 界   "])
    }

    func testWriteSanitizesControlCharacters() {
        var buffer = Buffer(width: 8, height: 1)
        XCTAssertEqual(buffer.write("a\u{1B}[2Jb", x: 0, y: 0), 6)
        XCTAssertEqual(buffer.plainLines(), ["a�[2Jb  "])
        XCTAssertFalse(buffer.lines(colors: true)[0].contains("\u{1B}[2J"))
    }

    func testZeroWidthCharactersAreSkipped() {
        var buffer = Buffer(width: 4, height: 1)
        XCTAssertEqual(buffer.write("a\u{200B}b", x: 0, y: 0), 2)
        XCTAssertEqual(buffer.plainLines(), ["ab  "])
    }

    func testWriteSpansAppliesEachStyleAndReturnsTotal() {
        var buffer = Buffer(width: 6, height: 1)
        let bold = TextStyle(bold: true)
        XCTAssertEqual(buffer.write([Span("ab", bold), Span("cd")], x: 1, y: 0, maxWidth: 4), 4)
        XCTAssertEqual(buffer[1, 0].style, bold)
        XCTAssertEqual(buffer[3, 0].style, .plain)
        XCTAssertEqual(buffer.plainLines(), [" abcd "])
        XCTAssertEqual(buffer.write([Span("xy"), Span("zw")], x: 0, y: 0, maxWidth: 3), 3)
        XCTAssertEqual(buffer.plainLines(), ["xyzcd "])
    }

    func testLinesWithoutColorsHaveNoEscapes() {
        var buffer = Buffer(width: 4, height: 1)
        buffer.write("ab", x: 0, y: 0, style: TextStyle(color: .red, bold: true))
        XCTAssertEqual(buffer.lines(colors: false), ["ab  "])
        XCTAssertEqual(buffer.plainLines(), ["ab  "])
    }

    func testLinesMergeEqualStylesIntoOneSequence() {
        var buffer = Buffer(width: 4, height: 1)
        buffer.write("ab", x: 0, y: 0, style: TextStyle(color: .cyan))
        XCTAssertEqual(buffer.lines(colors: true), ["\(esc)[0m\(esc)[36mab\(esc)[0m  "])
    }

    func testLinesSwitchBetweenStyles() {
        var buffer = Buffer(width: 3, height: 1)
        buffer.write([Span("a", TextStyle(bold: true)), Span("b", TextStyle(dim: true)), Span("c")], x: 0, y: 0)
        XCTAssertEqual(buffer.lines(colors: true), ["\(esc)[0m\(esc)[1ma\(esc)[0m\(esc)[2mb\(esc)[0mc"])
    }

    func testRowEndingStyledEndsWithReset() {
        var buffer = Buffer(width: 2, height: 1)
        buffer.write("ab", x: 0, y: 0, style: TextStyle(bold: true))
        XCTAssertEqual(buffer.lines(colors: true), ["\(esc)[0m\(esc)[1mab\(esc)[0m"])
    }

    func testStyleDoesNotCarryAcrossRows() {
        var buffer = Buffer(width: 1, height: 2)
        buffer.write("a", x: 0, y: 0, style: TextStyle(bold: true))
        buffer.write("b", x: 0, y: 1)
        XCTAssertEqual(buffer.lines(colors: true), ["\(esc)[0m\(esc)[1ma\(esc)[0m", "b"])
    }

    func testRowsKeepExactWidthWithWideCharacters() {
        var buffer = Buffer(width: 5, height: 2)
        buffer.write("界界", x: 0, y: 0, style: TextStyle(color: .green))
        buffer.write("a界", x: 0, y: 1)
        for line in buffer.lines(colors: true) + buffer.plainLines() {
            XCTAssertEqual(Term.displayWidth(line), 5)
        }
        XCTAssertEqual(buffer.plainLines(), ["界界 ", "a界  "])
    }

    func testClearBlanksRectAndKeepsOutside() {
        var buffer = Buffer(width: 5, height: 3)
        for row in 0..<3 { buffer.write("xxxxx", x: 0, y: row, style: TextStyle(bold: true)) }
        buffer.clear(Rect(x: 1, y: 1, width: 3, height: 1))
        XCTAssertEqual(buffer.plainLines(), ["xxxxx", "x   x", "xxxxx"])
        XCTAssertEqual(buffer[2, 1], Cell(symbol: " ", style: .plain))
    }

    func testClearIsClippedToBuffer() {
        var buffer = Buffer(width: 3, height: 2)
        for row in 0..<2 { buffer.write("xxx", x: 0, y: row) }
        buffer.clear(Rect(x: -2, y: 1, width: 4, height: 5))
        XCTAssertEqual(buffer.plainLines(), ["xxx", "  x"])
        buffer.clear(Rect(x: 5, y: 5, width: 2, height: 2))
        buffer.clear(Rect(x: 0, y: 0, width: 0, height: 2))
        XCTAssertEqual(buffer.plainLines(), ["xxx", "  x"])
    }

    func testClearBlanksOutsideHalfOfWideCharacterOnEdges() {
        var buffer = Buffer(width: 6, height: 1)
        buffer.write("界界界", x: 0, y: 0)
        buffer.clear(Rect(x: 1, y: 0, width: 4, height: 1))
        XCTAssertEqual(buffer.plainLines(), ["      "])
        var inner = Buffer(width: 6, height: 1)
        inner.write("界界界", x: 0, y: 0)
        inner.clear(Rect(x: 2, y: 0, width: 2, height: 1))
        XCTAssertEqual(inner.plainLines(), ["界  界"])
    }

    func testFadeKeepsSymbolsAndMakesEverythingDim() {
        var buffer = Buffer(width: 4, height: 2)
        buffer.write("a界", x: 0, y: 0, style: TextStyle(color: .red, bold: true, inverse: true))
        buffer.fade()
        let dim = TextStyle(dim: true)
        XCTAssertEqual(buffer.plainLines(), ["a界 ", "    "])
        XCTAssertEqual(buffer[0, 0], Cell(symbol: "a", style: dim))
        XCTAssertEqual(buffer[1, 0], Cell(symbol: "界", style: dim))
        XCTAssertEqual(buffer[2, 0], Cell(symbol: "", style: dim))
        XCTAssertEqual(buffer[0, 1], Cell(symbol: " ", style: dim))
    }
}
