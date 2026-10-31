import XCTest
@testable import TerminalUI

final class ScrollbarTests: XCTestCase {
    func testCenteredOffsetCentersFocusAndClamps() {
        XCTAssertEqual(Scrollbar.centeredOffset(total: 30, visible: 4, focus: 17), 15)
        XCTAssertEqual(Scrollbar.centeredOffset(total: 30, visible: 4, focus: 0), 0)
        XCTAssertEqual(Scrollbar.centeredOffset(total: 30, visible: 4, focus: 29), 26)
        XCTAssertEqual(Scrollbar.centeredOffset(total: 3, visible: 4, focus: 2), 0)
    }

    func testNoThumbWhenEverythingFitsOrTrackIsEmpty() {
        XCTAssertNil(Scrollbar(total: 5, visible: 5, offset: 0).thumb(trackHeight: 5))
        XCTAssertNil(Scrollbar(total: 3, visible: 5, offset: 0).thumb(trackHeight: 5))
        XCTAssertNil(Scrollbar(total: 10, visible: 5, offset: 0).thumb(trackHeight: 0))
    }

    func testThumbAtTopMiddleAndBottom() {
        XCTAssertEqual(Scrollbar(total: 100, visible: 10, offset: 0).thumb(trackHeight: 10), 0..<1)
        XCTAssertEqual(Scrollbar(total: 100, visible: 10, offset: 45).thumb(trackHeight: 10), 5..<6)
        XCTAssertEqual(Scrollbar(total: 100, visible: 10, offset: 90).thumb(trackHeight: 10), 9..<10)
        XCTAssertEqual(Scrollbar(total: 20, visible: 10, offset: 5).thumb(trackHeight: 8), 2..<6)
        XCTAssertEqual(Scrollbar(total: 20, visible: 10, offset: 10).thumb(trackHeight: 8), 4..<8)
    }

    func testOffsetIsClamped() {
        XCTAssertEqual(Scrollbar(total: 20, visible: 10, offset: 99).thumb(trackHeight: 8), 4..<8)
        XCTAssertEqual(Scrollbar(total: 20, visible: 10, offset: -4).thumb(trackHeight: 8), 0..<4)
    }

    func testThumbIsAtLeastOneRow() {
        XCTAssertEqual(Scrollbar(total: 1000, visible: 1, offset: 0).thumb(trackHeight: 5), 0..<1)
    }

    func testRenderDrawsThumbOverTrackRows() {
        var buffer = Buffer(width: 3, height: 8)
        Scrollbar(total: 8, visible: 4, offset: 0).render(column: 2, rows: 2..<6, buffer: &buffer, style: TextStyle(dim: true))
        XCTAssertEqual(buffer.plainLines().map { $0.suffix(1) }, [" ", " ", "┃", "┃", " ", " ", " ", " "])
        XCTAssertEqual(buffer[2, 2].style, TextStyle(dim: true))
    }

    func testRenderDrawsNothingWhenEverythingFits() {
        var buffer = Buffer(width: 3, height: 4)
        Scrollbar(total: 2, visible: 4, offset: 0).render(column: 2, rows: 0..<4, buffer: &buffer)
        XCTAssertEqual(buffer, Buffer(width: 3, height: 4))
    }
}
