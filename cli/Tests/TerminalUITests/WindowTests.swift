import XCTest
@testable import TerminalUI

final class WindowTests: XCTestCase {
    private func render(_ window: Window, width: Int, height: Int = 3) -> (lines: [String], buffer: Buffer, content: Rect) {
        var buffer = Buffer(width: width, height: height)
        let content = window.render(in: buffer.area, buffer: &buffer)
        return (buffer.plainLines(), buffer, content)
    }

    func testFrameWithoutInfo() {
        let result = render(Window(title: "Title"), width: 16)
        XCTAssertEqual(result.lines, [
            "╭─ Title ──────╮",
            "│              │",
            "╰──────────────╯"
        ])
    }

    func testFrameWithInfo() {
        let result = render(Window(title: "Title", info: "info"), width: 20)
        XCTAssertEqual(result.lines[0], "╭─ Title ─── info ─╮")
    }

    func testSidesAndBottomBorder() {
        let result = render(Window(title: "T"), width: 7)
        XCTAssertEqual(result.lines, ["╭─ T ─╮", "│     │", "╰─────╯"])
    }

    func testLongTitleIsTruncatedToSpaceLeftOfInfo() {
        let result = render(Window(title: "A very long title indeed", info: "info"), width: 20)
        XCTAssertEqual(result.lines[0], "╭─ A very… ─ info ─╮")
    }

    func testInfoStaysWholeWhileTitleHasFourColumns() {
        let result = render(Window(title: "Long title", info: "info"), width: 17)
        XCTAssertEqual(result.lines[0], "╭─ Lon… ─ info ─╮")
    }

    func testInfoIsDroppedWhenTitleWouldGetLessThanFourColumns() {
        let result = render(Window(title: "Long title here", info: "info"), width: 16)
        XCTAssertEqual(result.lines[0], "╭─ Long titl… ─╮")
    }

    func testLongTitleWithoutInfoKeepsDashBeforeCorner() {
        let result = render(Window(title: "PureMac cleaner"), width: 12)
        XCTAssertEqual(result.lines[0], "╭─ PureM… ─╮")
    }

    func testTopBorderAlwaysEndsWithDashBeforeCorner() {
        XCTAssertEqual(render(Window(title: "Title"), width: 10).lines[0], "╭─ Tit… ─╮")
        XCTAssertEqual(render(Window(title: "Title"), width: 11).lines[0], "╭─ Title ─╮")
    }

    func testStylesPerPart() {
        let window = Window(title: "Title", info: "info")
        let buffer = render(window, width: 20).buffer
        XCTAssertEqual(buffer[0, 0].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[0, 1].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[3, 0].style, TextStyle(color: .cyan, bold: true))
        XCTAssertEqual(buffer[13, 0].style, TextStyle(bold: true))
        XCTAssertEqual(buffer[19, 2].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[2, 0].style, .plain)
    }

    func testCustomStyles() {
        let yellow = TextStyle(color: .yellow)
        let window = Window(title: "T", borderStyle: yellow, titleStyle: yellow)
        let buffer = render(window, width: 7).buffer
        XCTAssertEqual(buffer[0, 1].style, yellow)
        XCTAssertEqual(buffer[3, 0].style, yellow)
    }

    func testContentRectHasOneColumnOfPadding() {
        var buffer = Buffer(width: 30, height: 10)
        let content = Window(title: "T").render(in: Rect(x: 2, y: 1, width: 20, height: 6), buffer: &buffer)
        XCTAssertEqual(content, Rect(x: 4, y: 2, width: 16, height: 4))
    }

    func testContentRectMatchesRenderWithoutDrawing() {
        var buffer = Buffer(width: 30, height: 10)
        let rect = Rect(x: 2, y: 1, width: 20, height: 6)
        let window = Window(title: "T")
        XCTAssertEqual(window.contentRect(in: rect), window.render(in: rect, buffer: &buffer))
        XCTAssertEqual(window.contentRect(in: Rect(x: 0, y: 0, width: 2, height: 2)), Rect(x: 2, y: 1, width: 0, height: 0))
    }

    func testContentRectOfTinyRectIsEmptyAtOrigin() {
        let window = Window(title: "T")
        XCTAssertEqual(window.contentRect(in: Rect(x: 3, y: 4, width: 1, height: 9)), Rect(x: 3, y: 4, width: 0, height: 0))
        XCTAssertEqual(window.contentRect(in: Rect(x: 3, y: 4, width: 9, height: 1)), Rect(x: 3, y: 4, width: 0, height: 0))
    }

    func testFrameIsDrawnAtRectOrigin() {
        var buffer = Buffer(width: 11, height: 5)
        Window(title: "T").render(in: Rect(x: 2, y: 1, width: 7, height: 3), buffer: &buffer)
        XCTAssertEqual(buffer.plainLines(), [
            "           ",
            "  ╭─ T ─╮  ",
            "  │     │  ",
            "  ╰─────╯  ",
            "           "
        ])
    }

    func testTinyRectDrawsNothing() {
        var buffer = Buffer(width: 6, height: 4)
        let blank = buffer
        let window = Window(title: "T")
        XCTAssertEqual(window.render(in: Rect(x: 1, y: 1, width: 1, height: 3), buffer: &buffer), Rect(x: 1, y: 1, width: 0, height: 0))
        XCTAssertEqual(window.render(in: Rect(x: 0, y: 0, width: 6, height: 1), buffer: &buffer), Rect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(buffer, blank)
    }

    func testSmallestFrameHasNonNegativeContent() {
        var buffer = Buffer(width: 2, height: 2)
        let content = Window(title: "T").render(in: buffer.area, buffer: &buffer)
        XCTAssertEqual(buffer.plainLines(), ["╭╮", "╰╯"])
        XCTAssertEqual(content, Rect(x: 2, y: 1, width: 0, height: 0))
    }

    func testDividerSpansWindowWidth() {
        var buffer = Buffer(width: 10, height: 5)
        let window = Window(title: "T")
        let rect = Rect(x: 2, y: 0, width: 6, height: 5)
        window.render(in: rect, buffer: &buffer)
        window.renderDivider(atRow: 2, in: rect, buffer: &buffer)
        XCTAssertEqual(buffer.plainLines()[2], "  ├────┤  ")
        XCTAssertEqual(buffer[2, 2].style, TextStyle(dim: true))
    }
}
