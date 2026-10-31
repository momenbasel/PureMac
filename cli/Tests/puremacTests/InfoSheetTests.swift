import XCTest
@testable import puremac
import TerminalUI

final class InfoSheetTests: XCTestCase {
    private let dim = TextStyle(dim: true)

    private func sample(extraRows: Int = 0) -> InfoSheet {
        InfoSheet(
            title: "Mac status",
            subtitle: "Read-only measurements",
            sections: [
                InfoSection(title: "Memory", rows: [
                    .gauge(fraction: 0.5, color: .green, text: "8 GB in use of 16 GB"),
                    .metric(label: "Pressure", value: [Span("Normal", TextStyle(color: .green))], note: nil),
                    .metric(label: "Installed", value: [Span("16 GB")], note: Span("saved", dim)),
                ] + (0..<extraRows).map { .message([Span("extra \($0)")]) }),
                InfoSection(title: nil, rows: [.message([Span("Uptime", dim), Span("  1h 1m")])]),
            ],
            footnote: "Nothing ran."
        )
    }

    func testPlainLinesWithoutColorsKeepTheCommandLayout() {
        XCTAssertEqual(sample().plainLines(colors: false), [
            "Mac status",
            "Read-only measurements",
            "",
            "Memory",
            "  ██████████░░░░░░░░░░ 8 GB in use of 16 GB",
            "  Pressure          Normal",
            "  Installed         16 GB  saved",
            "",
            "  Uptime  1h 1m",
            "",
            "Nothing ran.",
        ])
    }

    func testPlainLinesCanSkipTheHeader() {
        XCTAssertEqual(sample().plainLines(withHeader: false, colors: false).first, "Memory")
    }

    func testPlainLinesWithColorsStyleHeadingsLabelsAndGauge() {
        let lines = sample().plainLines(colors: true)
        XCTAssertEqual(lines[0], "\u{1B}[0m\u{1B}[1mMac status\u{1B}[0m")
        XCTAssertEqual(lines[1], "\u{1B}[0m\u{1B}[2mRead-only measurements\u{1B}[0m")
        XCTAssertTrue(lines[4].contains("\u{1B}[0m\u{1B}[32m██████████\u{1B}[0m\u{1B}[2m░░░░░░░░░░"), lines[4])
        XCTAssertTrue(lines[5].contains("\u{1B}[2mPressure"), lines[5])
        XCTAssertTrue(lines[5].contains("\u{1B}[32mNormal"), lines[5])
        XCTAssertTrue(lines[6].contains("\u{1B}[2msaved"), lines[6])
        XCTAssertEqual(lines.last, "\u{1B}[0m\u{1B}[2mNothing ran.\u{1B}[0m")
    }

    func testGaugeWithoutColorKeepsTheFilledPartPlain() {
        let sheet = InfoSheet(
            title: "T", subtitle: nil,
            sections: [InfoSection(title: nil, rows: [.gauge(fraction: 0.5, color: nil, text: "x")])],
            footnote: nil
        )
        XCTAssertEqual(
            sheet.plainLines(withHeader: false, colors: true),
            ["  ██████████\u{1B}[0m\u{1B}[2m░░░░░░░░░░\u{1B}[0m x"]
        )
    }

    func testPlainLinesShowAPathRowWithTwoSpacesAndNoTruncation() {
        let path = "/Users/x/Projects/some/deep/folder/name-0"
        let sheet = InfoSheet(title: "T", subtitle: nil, sections: [InfoSection(title: nil, rows: [.path(path)])], footnote: nil)
        XCTAssertEqual(sheet.plainLines(withHeader: false, colors: false), ["  " + path])
    }

    func testPlainLinesKeepZeroWidthCharactersInPaths() {
        let sheet = InfoSheet(title: "T", subtitle: nil, sections: [InfoSection(title: nil, rows: [.path("/tmp/a\u{200B}b")])], footnote: nil)
        XCTAssertEqual(sheet.plainLines(withHeader: false, colors: false), ["  /tmp/a\u{200B}b"])
    }

    func testSectionLabelWidthPadsPlainLabels() {
        let sheet = InfoSheet(
            title: "T", subtitle: nil,
            sections: [InfoSection(title: nil, labelWidth: 8, rows: [.metric(label: "Name", value: [Span("x")], note: nil)])],
            footnote: nil
        )
        XCTAssertEqual(sheet.plainLines(withHeader: false, colors: false), ["  Name     x"])
    }

    private func plain(_ lines: [[Span]]) -> [String] { lines.map { $0.map(\.text).joined() } }

    func testMetricMovesValueAndNoteToASecondRowWhenTheRowIsTooWide() {
        let row = InfoRow.metric(label: "purge.older_than_days", value: [Span("7 days")], note: Span("default", dim))
        let narrow = plain(InfoSheet.lines(row, labelWidth: 26, wrappingTo: 36))
        XCTAssertEqual(narrow, ["  purge.older_than_days", "    7 days  default"])
        let wide = plain(InfoSheet.lines(row, labelWidth: 26, wrappingTo: 76))
        XCTAssertEqual(wide.count, 1)
        XCTAssertTrue(wide[0].contains("7 days  default"))
        let short = InfoRow.metric(label: "Short", value: [Span("x")], note: nil)
        XCTAssertEqual(InfoSheet.lines(short, labelWidth: 26, wrappingTo: 36).count, 1)
    }

    func testMetricMiddleTruncatesALongValueOnItsSecondRow() {
        let path = "/Users/someone/.config/puremac/deep/config.json"
        let rows = plain(InfoSheet.lines(.metric(label: "Settings", value: [Span(path)], note: nil), labelWidth: 12, wrappingTo: 36))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].hasPrefix("    /Users") && rows[1].contains("…") && rows[1].hasSuffix("config.json"), rows[1])
        XCTAssertLessThanOrEqual(rows[1].count, 36)
    }

    func testGaugeShrinksItsBarSoTheWholeTextFits() {
        let text = "107.4 GB free of 536.9 GB"
        let row = InfoRow.gauge(fraction: 0.8, color: .green, text: text)
        let narrow = plain(InfoSheet.lines(row, labelWidth: 17, wrappingTo: 36))[0]
        XCTAssertTrue(narrow.hasSuffix(text), narrow)
        XCTAssertLessThanOrEqual(narrow.count, 36)
        XCTAssertEqual(plain(InfoSheet.lines(row, labelWidth: 17, wrappingTo: 76))[0].filter { "█░".contains($0) }.count, 20)
    }

    func testGaugeWithoutRoomForABarShowsOnlyItsText() {
        let text = String(repeating: "y", count: 33)
        let row = plain(InfoSheet.lines(.gauge(fraction: 0.5, color: .green, text: text), labelWidth: 17, wrappingTo: 36))
        XCTAssertEqual(row, ["  " + text])
    }

    func testMessageWrapsKeepingSpanStyles() {
        let cyan = TextStyle(color: .cyan)
        let spans = [Span("No protected paths. Add one with ", dim), Span("`puremac ignore add <path>`", cyan), Span(".", dim)]
        let rows = InfoSheet.lines(.message(spans), labelWidth: 17, wrappingTo: 36)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertTrue(plain(rows).allSatisfy { $0.hasPrefix("  ") && $0.count <= 36 })
        let styled = rows.flatMap { $0 }.filter { $0.style == cyan }.map(\.text).joined(separator: " ")
        XCTAssertEqual(styled, "`puremac ignore add <path>`")
        XCTAssertFalse(plain(rows).joined().contains("…"))
    }
}
