import XCTest
@testable import TerminalUI

final class StyleTests: XCTestCase {
    func testPlainStyleHasNoParameters() {
        XCTAssertEqual(TextStyle.plain.sgrParameters, "")
        XCTAssertEqual(TextStyle(), .plain)
    }

    func testParametersFollowFixedOrder() {
        XCTAssertEqual(TextStyle(color: .cyan, bold: true, dim: true, inverse: true).sgrParameters, "1;2;7;36")
        XCTAssertEqual(TextStyle(color: .red).sgrParameters, "31")
        XCTAssertEqual(TextStyle(dim: true).sgrParameters, "2")
        XCTAssertEqual(TextStyle(inverse: true).sgrParameters, "7")
    }

    func testColorCodes() {
        let codes: [(TerminalColor, String)] = [(.red, "31"), (.green, "32"), (.yellow, "33"), (.cyan, "36")]
        for (color, code) in codes {
            XCTAssertEqual(TextStyle(color: color).sgrParameters, code)
        }
    }

    func testSpanDefaultsToPlain() {
        XCTAssertEqual(Span("a").style, .plain)
        XCTAssertEqual(Span("a", TextStyle(bold: true)).style.bold, true)
    }
}
