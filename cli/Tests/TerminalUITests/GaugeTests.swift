import XCTest
@testable import TerminalUI

final class GaugeTests: XCTestCase {
    private let dim = TextStyle(dim: true)

    func testFilledAndRestSpans() {
        XCTAssertEqual(Gauge(fraction: 0.5).spans(width: 10), [Span("█████"), Span("░░░░░", dim)])
    }

    func testFilledPartTakesGivenStyleAndRestStaysDim() {
        let green = TextStyle(color: .green)
        XCTAssertEqual(Gauge(fraction: 0.5).spans(width: 10, filled: green), [Span("█████", green), Span("░░░░░", dim)])
        XCTAssertEqual(Gauge(fraction: 1).spans(width: 4, filled: green), [Span("████", green)])
        XCTAssertEqual(Gauge(fraction: 0).spans(width: 4, filled: green), [Span("░░░░", dim)])
    }

    func testEmptyAndFullHaveSingleSpan() {
        XCTAssertEqual(Gauge(fraction: 0).spans(width: 4), [Span("░░░░", dim)])
        XCTAssertEqual(Gauge(fraction: 1).spans(width: 4), [Span("████")])
    }

    func testFractionIsClamped() {
        XCTAssertEqual(Gauge(fraction: 2).spans(width: 3), [Span("███")])
        XCTAssertEqual(Gauge(fraction: -1).spans(width: 3), [Span("░░░", dim)])
    }

    func testNonPositiveWidthHasNoSpans() {
        XCTAssertEqual(Gauge(fraction: 0.5).spans(width: 0), [])
        XCTAssertEqual(Gauge(fraction: 0.5).spans(width: -3), [])
    }

    func testRoundingOfFilledCells() {
        let cases: [(Double, Int, String)] = [
            (0.25, 8, "██░░░░░░"), (0.5, 5, "███░░"), (0.49, 12, "██████░░░░░░"), (0.99, 24, "████████████████████████")
        ]
        for (fraction, width, expected) in cases {
            XCTAssertEqual(Gauge(fraction: fraction).spans(width: width).map(\.text).joined(), expected)
        }
    }
}
