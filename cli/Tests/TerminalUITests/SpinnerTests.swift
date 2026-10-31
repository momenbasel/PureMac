import XCTest
@testable import TerminalUI

final class SpinnerTests: XCTestCase {
    func testFramesCycleThroughBrailleSequence() {
        let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".map(String.init)
        for tick in 0..<frames.count {
            XCTAssertEqual(Spinner.frame(tick: tick), frames[tick])
        }
        XCTAssertEqual(Spinner.frame(tick: frames.count), frames[0])
        XCTAssertEqual(Spinner.frame(tick: frames.count + 3), frames[3])
    }
}
