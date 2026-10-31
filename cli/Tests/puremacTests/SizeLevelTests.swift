import XCTest
@testable import puremac
import TerminalUI

final class SizeLevelTests: XCTestCase {
    func testThresholdsUseDecimalUnits() {
        XCTAssertEqual(SizeLevel(bytes: 0).color, .green)
        XCTAssertEqual(SizeLevel(bytes: 99_999_999).color, .green)
        XCTAssertEqual(SizeLevel(bytes: 100_000_000).color, .yellow)
        XCTAssertEqual(SizeLevel(bytes: 999_999_999).color, .yellow)
        XCTAssertEqual(SizeLevel(bytes: 1_000_000_000).color, .red)
    }

    func testStyleIsColoredWhenUnfocusedAndInverseWhenFocused() {
        XCTAssertEqual(SizeLevel.style(bytes: 150_000_000, focused: false), TextStyle(color: .yellow))
        XCTAssertEqual(SizeLevel.style(bytes: 150_000_000, focused: true), TextStyle(inverse: true))
    }
}
