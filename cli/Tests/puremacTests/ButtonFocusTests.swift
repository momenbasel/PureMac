import XCTest
import TerminalUI
@testable import puremac

final class ButtonFocusTests: XCTestCase {
    func testMovesWithClamping() {
        var focus = ButtonFocus(count: 2, index: 0)
        focus.move(-1)
        XCTAssertEqual(focus.index, 0)
        focus.move(1)
        XCTAssertEqual(focus.index, 1)
        focus.move(1)
        XCTAssertEqual(focus.index, 1)
        focus.move(-1)
        XCTAssertEqual(focus.index, 0)
    }

    func testCycleWraps() {
        var focus = ButtonFocus(count: 2, index: 0)
        focus.cycle()
        XCTAssertEqual(focus.index, 1)
        focus.cycle()
        XCTAssertEqual(focus.index, 0)
    }

    func testNavigateHandlesOnlyLeftRightAndTab() {
        var focus = ButtonFocus(count: 2, index: 0)
        XCTAssertTrue(focus.navigate(.right))
        XCTAssertEqual(focus.index, 1)
        XCTAssertTrue(focus.navigate(.left))
        XCTAssertEqual(focus.index, 0)
        XCTAssertTrue(focus.navigate(.tab))
        XCTAssertEqual(focus.index, 1)
        for key in [TerminalKey.enter, .escape, .up, .character("q")] {
            XCTAssertFalse(focus.navigate(key))
            XCTAssertEqual(focus.index, 1)
        }
    }
}
