import XCTest
@testable import TerminalUI

final class DialogTests: XCTestCase {
    private let area = Rect(x: 0, y: 0, width: 40, height: 12)

    private func render(_ dialog: Dialog, in area: Rect, fill: String? = nil) -> (frame: Rect, buffer: Buffer, rows: [String]) {
        var buffer = Buffer(width: area.width, height: area.height)
        if let fill {
            for row in 0..<area.height { buffer.write(String(repeating: fill, count: area.width), x: 0, y: row) }
        }
        dialog.render(in: area, buffer: &buffer)
        let frame = dialog.frame(in: area)
        let rows = buffer.plainLines().dropFirst(frame.y).prefix(frame.height).map {
            String($0.dropFirst(frame.x).prefix(frame.width))
        }
        return (frame, buffer, rows)
    }

    private func simple(message: String = "Hello", buttons: [DialogButton] = [DialogButton("OK")]) -> Dialog {
        Dialog(title: "Hi", message: [Span(message)], buttons: buttons)
    }

    func testMaxContentWidthLeavesTheMarginAroundTheFrame() {
        XCTAssertEqual(Dialog.maxContentWidth(in: Rect(x: 0, y: 0, width: 80, height: 24)), 70)
        XCTAssertEqual(Dialog.maxContentWidth(in: Rect(x: 0, y: 0, width: 4, height: 24)), 1)
    }

    func testFrameIsCenteredAndSizedToContent() {
        let dialog = simple()
        XCTAssertEqual(dialog.frame(in: area), Rect(x: 14, y: 2, width: 12, height: 7))
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ Hi ─────╮",
            "│          │",
            "│  Hello   │",
            "│          │",
            "│  [ OK ]  │",
            "│          │",
            "╰──────────╯"
        ])
    }

    func testFrameIsCenteredInOffsetArea() {
        let frame = simple().frame(in: Rect(x: 10, y: 2, width: 40, height: 12))
        XCTAssertEqual(frame, Rect(x: 24, y: 4, width: 12, height: 7))
    }

    func testContentWidthIsWidestOfMessageButtonsAndHints() {
        let wideButtons = simple(buttons: [DialogButton("Cancel"), DialogButton("Remove")])
        XCTAssertEqual(wideButtons.frame(in: area).width, 22 + 6)
        var withHints = simple()
        withHints.hints = KeyHints([KeyHint("Esc", "back"), KeyHint("Enter", "select")])
        XCTAssertEqual(withHints.frame(in: area).width, Term.displayWidth("Esc back  Enter select") + 6)
    }

    func testWidthIsCappedToMarginsAndMessageWraps() {
        let dialog = simple(message: String(repeating: "word ", count: 30))
        let result = render(dialog, in: area)
        XCTAssertEqual(result.frame.width, 36)
        XCTAssertEqual(result.frame.x, 2)
        XCTAssertTrue(result.rows[2].contains("word word"))
        XCTAssertTrue(result.rows.allSatisfy { Term.displayWidth($0) == 36 })
    }

    func testMessageWrapsOnSpacesAndEachParagraphOnItsOwn() {
        let dialog = Dialog(
            title: "T",
            message: [Span("aaa bbb ccc ddd"), Span("ee")],
            buttons: []
        )
        let result = render(dialog, in: Rect(x: 0, y: 0, width: 20, height: 12))
        XCTAssertEqual(result.frame.width, 16)
        XCTAssertEqual(Array(result.rows[2...4]), ["│   aaa bbb    │", "│   ccc ddd    │", "│      ee      │"])
    }

    func testLongWordIsHardBrokenByDisplayWidth() {
        let dialog = Dialog(title: "T", message: [Span("abcdefghij 界界界")], buttons: [])
        let result = render(dialog, in: Rect(x: 0, y: 0, width: 15, height: 12))
        let rows = result.buffer.plainLines().dropFirst(result.frame.y + 2).prefix(4).map { String($0.dropFirst(2).dropLast(2)) }
        XCTAssertEqual(rows, ["│  abcde  │", "│  fghij  │", "│  界界   │", "│   界    │"])
    }

    func testDropsBlankRowFirstWhenHeightIsShort() {
        let message = (1...7).map { Span("line \($0)") }
        let dialog = Dialog(title: "T", message: message, buttons: [DialogButton("OK")])
        let result = render(dialog, in: area)
        XCTAssertEqual(result.frame.height, 10)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertTrue(result.rows[7].contains("line 7"))
        XCTAssertTrue(result.rows[8].contains("[ OK ]"))
    }

    func testDropsTrailingMessageRowsAfterBlankRow() {
        let message = (1...10).map { Span("line \($0)") }
        var dialog = Dialog(title: "T", message: message, buttons: [DialogButton("OK")])
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        let result = render(dialog, in: area)
        XCTAssertEqual(result.frame, Rect(x: result.frame.x, y: 1, width: result.frame.width, height: 10))
        XCTAssertTrue(result.rows[6].contains("line 6"))
        XCTAssertFalse(result.rows.joined().contains("line 7"))
        XCTAssertTrue(result.rows[7].contains("[ OK ]"))
        XCTAssertTrue(result.rows[8].contains("Esc back"))
    }

    private func buttonStyles(focused: Int?, buttons: [DialogButton]) -> (start: Int, row: Int, buffer: Buffer) {
        var dialog = simple(buttons: buttons)
        dialog.focusedButton = focused
        let result = render(dialog, in: area)
        let rowIndex = result.frame.y + 4
        let line = result.buffer.plainLines()[rowIndex]
        let start = line.distance(from: line.startIndex, to: line.range(of: "Cancel")!.lowerBound) - 2
        return (start, rowIndex, result.buffer)
    }

    private let both = [DialogButton("Cancel"), DialogButton("Remove", role: .destructive)]

    func testButtonsAreTwoSpacesApart() {
        let result = render(simple(buttons: both), in: area)
        XCTAssertEqual(result.rows[4], "│  [ Cancel ]  [ Remove ]  │")
    }

    func testFocusedButtonIsWrittenWithPointersAtTheSameWidth() {
        var dialog = simple(buttons: both)
        dialog.focusedButton = 0
        XCTAssertEqual(render(dialog, in: area).rows[4], "│  › Cancel ‹  [ Remove ]  │")
        dialog.focusedButton = 1
        XCTAssertEqual(render(dialog, in: area).rows[4], "│  [ Cancel ]  › Remove ‹  │")
    }

    func testFocusedNormalButtonIsInverse() {
        let found = buttonStyles(focused: 0, buttons: both)
        for column in found.start..<(found.start + 10) {
            XCTAssertEqual(found.buffer[column, found.row].style, TextStyle(inverse: true))
        }
        XCTAssertEqual(found.buffer[found.start + 12, found.row].style, TextStyle(color: .red))
        XCTAssertEqual(found.buffer[found.start + 10, found.row].style, .plain)
    }

    func testFocusedDestructiveButtonIsRedAndInverse() {
        let found = buttonStyles(focused: 1, buttons: both)
        XCTAssertEqual(found.buffer[found.start, found.row].style, .plain)
        for column in (found.start + 12)..<(found.start + 22) {
            XCTAssertEqual(found.buffer[column, found.row].style, TextStyle(color: .red, inverse: true))
        }
    }

    func testNoFocusLeavesButtonsUnhighlighted() {
        let found = buttonStyles(focused: nil, buttons: both)
        XCTAssertEqual(found.buffer[found.start, found.row].style, .plain)
        XCTAssertEqual(found.buffer[found.start + 12, found.row].style, TextStyle(color: .red))
    }

    func testMessageButtonsAndHintsAreCenteredWithBlankRowsBetweenGroups() {
        var dialog = simple()
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ Hi ───────╮",
            "│            │",
            "│   Hello    │",
            "│            │",
            "│   [ OK ]   │",
            "│            │",
            "│  Esc back  │",
            "│            │",
            "╰────────────╯"
        ])
    }

    func testHintRowNarrowerThanContentIsCentered() {
        var dialog = Dialog(title: "Hi", message: [Span("Hello, world!")])
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ Hi ────────────╮",
            "│                 │",
            "│  Hello, world!  │",
            "│                 │",
            "│    Esc back     │",
            "│                 │",
            "╰─────────────────╯"
        ])
    }

    func testWrappedHintRowsAreCenteredIndependently() {
        var dialog = Dialog(title: "T", message: [Span(String(repeating: "x", count: 40))])
        dialog.hints = KeyHints([
            KeyHint("Enter", "select"), KeyHint("Esc", "back"), KeyHint("Tab", "next"), KeyHint("Space", "toggle")
        ])
        let rows = render(dialog, in: Rect(x: 0, y: 0, width: 42, height: 14)).rows
        XCTAssertEqual(Array(rows.suffix(4)), [
            "│  Enter select  Esc back  Tab next  │",
            "│            Space toggle            │",
            "│" + String(repeating: " ", count: 36) + "│",
            "╰" + String(repeating: "─", count: 36) + "╯"
        ])
    }

    func testBlankRowsAppearOnlyBetweenGroupsThatExist() {
        var messageAndHints = Dialog(title: "T", message: [Span("Hello")])
        messageAndHints.hints = KeyHints([KeyHint("Esc", "back")])
        XCTAssertEqual(render(messageAndHints, in: area).rows, [
            "╭─ T ────────╮",
            "│            │",
            "│   Hello    │",
            "│            │",
            "│  Esc back  │",
            "│            │",
            "╰────────────╯"
        ])
        XCTAssertEqual(render(Dialog(title: "Title", buttons: [DialogButton("OK")]), in: area).rows, [
            "╭─ Title ───╮",
            "│           │",
            "│  [ OK ]   │",
            "│           │",
            "╰───────────╯"
        ])
    }

    func testDialogWithoutMessageHasABlankRowAboveItsFirstGroup() {
        var dialog = Dialog(title: "T", buttons: [DialogButton("OK")])
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ T ────────╮",
            "│            │",
            "│   [ OK ]   │",
            "│            │",
            "│  Esc back  │",
            "│            │",
            "╰────────────╯"
        ])
        XCTAssertEqual(render(dialog, in: Rect(x: 0, y: 0, width: 40, height: 8)).rows, [
            "╭─ T ────────╮",
            "│            │",
            "│   [ OK ]   │",
            "│            │",
            "│  Esc back  │",
            "╰────────────╯"
        ])
        XCTAssertEqual(render(dialog, in: Rect(x: 0, y: 0, width: 40, height: 6)).rows, [
            "╭─ T ────────╮",
            "│   [ OK ]   │",
            "│  Esc back  │",
            "╰────────────╯"
        ])
    }

    func testDropsBlankRowsBottomUpBeforeAnyMessageRow() {
        var dialog = Dialog(title: "T", message: (1...4).map { Span("line \($0)") }, buttons: [DialogButton("OK")])
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        let droppedTwoBlankRows = render(dialog, in: area).rows
        XCTAssertEqual(droppedTwoBlankRows.count, 10)
        XCTAssertTrue(droppedTwoBlankRows[1].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(droppedTwoBlankRows[2].contains("line 1"))
        XCTAssertTrue(droppedTwoBlankRows[5].contains("line 4"))
        XCTAssertTrue(droppedTwoBlankRows[6].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(droppedTwoBlankRows[7].contains("[ OK ]"))
        XCTAssertTrue(droppedTwoBlankRows[8].contains("Esc back"))

        dialog.message = (1...5).map { Span("line \($0)") }
        let droppedThreeBlankRows = render(dialog, in: area).rows
        XCTAssertEqual(droppedThreeBlankRows.count, 10)
        XCTAssertTrue(droppedThreeBlankRows[1].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(droppedThreeBlankRows[6].contains("line 5"))
        XCTAssertTrue(droppedThreeBlankRows[7].contains("[ OK ]"))
        XCTAssertTrue(droppedThreeBlankRows[8].contains("Esc back"))
    }

    func testBottomBlankRowIsDroppedBeforeTheOtherBlankRows() {
        var dialog = Dialog(title: "T", message: [Span("a"), Span("b")], buttons: [DialogButton("OK")])
        dialog.hints = KeyHints([KeyHint("Esc", "back")])
        let fits = render(dialog, in: Rect(x: 0, y: 0, width: 40, height: 12))
        XCTAssertEqual(fits.rows.count, 10)
        XCTAssertTrue(fits.rows[8].allSatisfy { $0 == " " || $0 == "│" })
        let tight = render(dialog, in: Rect(x: 0, y: 0, width: 40, height: 11)).rows
        XCTAssertEqual(tight.count, 9)
        XCTAssertTrue(tight[1].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(tight[4].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(tight[6].allSatisfy { $0 == " " || $0 == "│" })
        XCTAssertTrue(tight[7].contains("Esc back"))
    }

    func testLeadingMessageAlignmentKeepsRowsInTheFirstContentColumn() {
        var dialog = Dialog(
            title: "T",
            message: [Span("a"), Span("longer text")],
            buttons: [DialogButton("OK")]
        )
        dialog.messageAlignment = .leading
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ T ───────────╮",
            "│               │",
            "│  a            │",
            "│  longer text  │",
            "│               │",
            "│    [ OK ]     │",
            "│               │",
            "╰───────────────╯"
        ])
    }

    func testCenteredMessageWrapsBalancedAndLeadingKeepsGreedyWrap() {
        let text = "Searching 1 folder for build artifacts can take a few minutes."
        let wide = Rect(x: 0, y: 0, width: 64, height: 18)
        var dialog = Dialog(title: "T", message: [Span(text)], buttons: [])
        let centered = render(dialog, in: wide).rows.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│ ")) }
        XCTAssertTrue(centered.contains("Searching 1 folder for build"))
        XCTAssertTrue(centered.contains("artifacts can take a few minutes."))

        dialog.messageAlignment = .leading
        let leading = render(dialog, in: wide).rows.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│ ")) }
        XCTAssertTrue(leading.contains("Searching 1 folder for build artifacts can take a few"))
        XCTAssertTrue(leading.contains("minutes."))
    }

    func testCenterMessageAlignmentIsTheDefault() {
        let dialog = Dialog(title: "T", message: [Span("a"), Span("longer text")])
        XCTAssertEqual(render(dialog, in: area).rows[2], "│       a       │")
    }

    func testBorderAndTitleStylesApply() {
        var dialog = simple()
        dialog.borderStyle = TextStyle(color: .yellow)
        dialog.titleStyle = TextStyle(color: .yellow, bold: true)
        let result = render(dialog, in: area)
        XCTAssertEqual(result.buffer[result.frame.x, result.frame.y].style, TextStyle(color: .yellow))
        XCTAssertEqual(result.buffer[result.frame.x + 3, result.frame.y].style, TextStyle(color: .yellow, bold: true))
        XCTAssertEqual(Dialog(title: "T").borderStyle, .plain)
        XCTAssertEqual(Dialog(title: "T").titleStyle, TextStyle(bold: true))
    }

    func testRenderClearsBackgroundInsideFrameOnly() {
        let result = render(simple(), in: area, fill: "x")
        let lines = result.buffer.plainLines()
        XCTAssertEqual(lines[1], String(repeating: "x", count: 40))
        XCTAssertEqual(lines[4], String(repeating: "x", count: 14) + "│  Hello   │" + String(repeating: "x", count: 14))
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(result.buffer.lines(colors: true).allSatisfy { Term.displayWidth($0) == 40 })
    }

    func testBlankBackgroundStyleIsResetInsideFrame() {
        var buffer = Buffer(width: 40, height: 12)
        buffer.fade()
        simple().render(in: buffer.area, buffer: &buffer)
        XCTAssertEqual(buffer[16, 4].style, .plain)
        XCTAssertEqual(buffer[0, 0].style, TextStyle(dim: true))
    }

    func testStatusDialogWithoutButtonsOrHintsHasBlankRowsAroundMessage() {
        let dialog = Dialog(title: "Working", message: [Span("Removing 2 items…")])
        XCTAssertEqual(render(dialog, in: area).rows, [
            "╭─ Working ───────────╮",
            "│                     │",
            "│  Removing 2 items…  │",
            "│                     │",
            "╰─────────────────────╯"
        ])
    }

    func testContentWidthFitsTitle() {
        let shortMessage = Dialog(title: "Cleanup complete", message: [Span("1 KB removed")])
        XCTAssertEqual(render(shortMessage, in: area).rows, [
            "╭─ Cleanup complete ───╮",
            "│                      │",
            "│     1 KB removed     │",
            "│                      │",
            "╰──────────────────────╯"
        ])
        let titleOnly = Dialog(title: "Removing 2 items…")
        XCTAssertEqual(render(titleOnly, in: area).rows, [
            "╭─ Removing 2 items… ───╮",
            "╰───────────────────────╯"
        ])
    }

    func testMaxTitleWidthLeavesRoomForTheBorderPadding() {
        XCTAssertEqual(Dialog.maxTitleWidth(in: Rect(x: 0, y: 0, width: 80, height: 24)), 68)
        XCTAssertEqual(Dialog.maxTitleWidth(in: Rect(x: 0, y: 0, width: 4, height: 24)), 1)
    }

    func testButtonsThatDoNotFitSideBySideStackOnePerRowCentered() throws {
        let dialog = Dialog(
            title: "Hi",
            message: [Span("Sure?")],
            buttons: [DialogButton("Cancel"), DialogButton("Remove protection", role: .destructive)]
        )
        let result = render(dialog, in: area)
        let content = (x: 3, width: result.frame.width - 6)
        let cancelRow = 4
        for (offset, title) in ["[ Cancel ]", "[ Remove protection ]"].enumerated() {
            let row = result.rows[cancelRow + offset]
            let start = try XCTUnwrap(row.range(of: title), row).lowerBound
            XCTAssertEqual(row.distance(from: row.startIndex, to: start), content.x + (content.width - title.count) / 2, row)
        }
    }
}
