import XCTest
@testable import TerminalUI

final class TerminalSessionTests: XCTestCase {
    private let esc = "\u{1B}"

    func testFrameClearsBelowOnlyWhenFrameIsShorterThanScreen() {
        XCTAssertTrue(TerminalSession.frame(lines: ["a", "b"], height: 3).hasSuffix("\(esc)[J"))
        XCTAssertFalse(TerminalSession.frame(lines: ["a", "b", "c"], height: 3).hasSuffix("\(esc)[J"))
        XCTAssertTrue(TerminalSession.frame(lines: ["a", "b", "c", "d"], height: 3).contains("c"))
        XCTAssertFalse(TerminalSession.frame(lines: ["a", "b", "c", "d"], height: 3).contains("d"))
    }

    func testSimpleBytesDecodeToKeys() {
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x09), .tab)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x0D), .enter)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x0A), .enter)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x20), .space)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x7F), .backspace)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x08), .backspace)
        XCTAssertEqual(TerminalSession.key(forSimpleByte: 0x01), .unknown)
        XCTAssertNil(TerminalSession.key(forSimpleByte: 0x1B))
        XCTAssertNil(TerminalSession.key(forSimpleByte: 0x61))
    }
}
