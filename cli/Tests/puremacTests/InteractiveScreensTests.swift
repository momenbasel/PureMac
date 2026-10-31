import XCTest
@testable import puremac
import TerminalUI

final class InteractiveScreensTests: XCTestCase {
    func testReviewStartsWithNothingSelected() {
        let model = InteractiveReviewModel(categories: fixtureCategories())
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertEqual(model.selectedBytes, 0)
        XCTAssertEqual(model.matchingAddresses.count, 3)
    }

    func testEditQueryTypesFiltersAndDeletes() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        for key in [TerminalKey.character("s"), .character("e"), .character("c")] { model.editQuery(key) }
        XCTAssertEqual(model.query, "sec")
        XCTAssertEqual(model.matchingAddresses.count, 1)
        model.editQuery(.backspace)
        model.editQuery(.delete)
        XCTAssertEqual(model.query, "s")
        model.editQuery(.space)
        XCTAssertEqual(model.query, "s ")
    }

    func testEditQueryIgnoresControlKeysAndKeepsFocusWhenNothingChanged() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.move(2)
        model.status = "note"
        model.editQuery(.backspace)
        model.editQuery(.up)
        model.editQuery(.character("\u{7F}"))
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.focusedAddress, model.matchingAddresses[2])
        XCTAssertEqual(model.status, "note")
    }

    func testReviewSelectionAndSearchPreserveExactItems() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        model.move(1)
        model.toggleFocused()
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.selectedBytes, 3_000)

        model.updateQuery("second")
        XCTAssertEqual(model.matchingAddresses.count, 1)
        XCTAssertEqual(model.item(at: model.matchingAddresses[0]).path, "/tmp/second")

        model.selectNone()
        model.selectAllMatching()
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.selectedResult()[0].selectedItems.map(\.path), ["/tmp/second"])
    }

    func testReviewRenderIsBoundedAndKeepsControlsVisible() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.selectAllMatching()
        for (width, height) in [(40, 12), (58, 14), (80, 24)] {
            let lines = renderReview(model, width: width, height: height).plainLines()

            XCTAssertEqual(lines.count, height)
            XCTAssertTrue(lines.contains { $0.contains("Space toggle") })
            XCTAssertTrue(lines.contains { $0.contains("Enter remove") })
            XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == width })
        }
    }

    func testReviewWindowShowsTitleAndSelectionSummaryInTopBorder() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        let lines = renderReview(model, width: 80, height: 24).plainLines()
        XCTAssertTrue(lines[0].hasPrefix("╭─ Review removable files "))
        XCTAssertTrue(lines[0].hasSuffix(" 1 selected · 1 KB ─╮"))
        XCTAssertFalse(lines.contains { $0.contains("PUREMAC") })
    }

    func testReviewHeaderFitsFortyColumnsWithDifferentCountsAndSizes() {
        let categories = [
            CategoryScan(
                id: "cache",
                title: "Caches",
                groups: [
                    ToolGroup(
                        tool: "Applications",
                        items: [
                            ScanItem(path: "/tmp/one", sizeBytes: 138_300, modified: nil),
                            ScanItem(path: "/tmp/two", sizeBytes: 1_000, modified: nil)
                        ]
                    )
                ]
            )
        ]
        let lines = renderReview(InteractiveReviewModel(categories: categories), width: 40, height: 12).plainLines()

        XCTAssertTrue(lines[0].contains("0 selected"))
        XCTAssertTrue(lines[1].contains("2 shown"))
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
    }

    func testReviewFirstRowShowsFoundSummaryDimWhenIdle() {
        let buffer = renderReview(InteractiveReviewModel(categories: fixtureCategories()), width: 80, height: 24)
        XCTAssertTrue(buffer.plainLines()[1].hasPrefix("│ 3 shown · 6 KB"))
        XCTAssertEqual(buffer[2, 1].style, TextStyle(dim: true))
    }

    func testReviewFirstRowShowsSearchFieldWithCursorAndRightAlignedSummary() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.isSearching = true
        model.updateQuery("sec")
        let buffer = renderReview(model, width: 80, height: 24)
        let line = buffer.plainLines()[1]
        XCTAssertTrue(line.hasPrefix("│ Search  sec "))
        XCTAssertTrue(line.hasSuffix("1 shown · 6 KB │"))
        XCTAssertEqual(buffer[2, 1].style, TextStyle(color: .cyan))
        XCTAssertEqual(buffer[13, 1].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[line.count - 4, 1].style, TextStyle(dim: true))
    }

    func testReviewFirstRowShowsStatusInYellowAndFilterDim() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.selectAllMatching()
        var buffer = renderReview(model, width: 80, height: 24)
        XCTAssertTrue(buffer.plainLines()[1].hasPrefix("│ Selected visible items"))
        XCTAssertEqual(buffer[2, 1].style, TextStyle(color: .yellow))

        model.updateQuery("first")
        buffer = renderReview(model, width: 80, height: 24)
        XCTAssertTrue(buffer.plainLines()[1].hasPrefix("│ Filter  first"))
        XCTAssertEqual(buffer[2, 1].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[10, 1].style, TextStyle(dim: true))
    }

    func testReviewFirstRowOmitsSummaryWhenItDoesNotFit() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.isSearching = true
        model.updateQuery(String(repeating: "x", count: 30))
        let line = renderReview(model, width: 40, height: 12).plainLines()[1]
        XCTAssertFalse(line.contains("shown"))
    }

    func testReviewSearchFieldKeepsTheEndOfALongQueryNextToTheCursor() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.isSearching = true
        model.updateQuery("abcdefghijklmnopqrstuvwxyz0123456789")
        let buffer = renderReview(model, width: 40, height: 12)
        XCTAssertEqual(buffer.plainLines()[1], "│ Search  …klmnopqrstuvwxyz0123456789  │")
        XCTAssertEqual(buffer[37, 1].style, TextStyle(inverse: true))
    }

    func testReviewRowsShowCategoryGroupAndItemsWithFocus() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        let lines = renderReview(model, width: 60, height: 24).plainLines()
        XCTAssertEqual(lines[2], "│ Developer" + String(repeating: " ", count: 48) + "│")
        XCTAssertTrue(lines[3].hasPrefix("│ Build caches"))
        XCTAssertTrue(lines[3].hasSuffix("2 items │"))
        XCTAssertTrue(lines[4].hasPrefix("│ › ● 1 KB       /tmp/first"))
        XCTAssertTrue(lines[5].hasPrefix("│   ○ 2 KB       /tmp/second"))
        XCTAssertTrue(lines[6].hasSuffix("1 item │"))
    }

    func testReviewRowsStyleCategoryGroupAndFocusedItem() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        let buffer = renderReview(model, width: 60, height: 24)
        XCTAssertEqual(buffer[2, 2].style, TextStyle(bold: true))
        XCTAssertEqual(buffer[2, 3].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[56, 3].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[2, 4].style, TextStyle(color: .cyan, inverse: true))
        XCTAssertEqual(buffer[4, 4].style, TextStyle(color: .cyan, inverse: true))
        XCTAssertEqual(buffer[16, 4].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[55, 4].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[4, 5].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[16, 5].style, .plain)
    }

    func testReviewItemSizeIsColoredByMagnitudeExceptOnFocusedRow() {
        let sizes: [Int64] = [5, 150_000_000, 2_000_000_000]
        let items = sizes.enumerated().map { ScanItem(path: "/tmp/\($0.offset)", sizeBytes: $0.element, modified: nil, selected: false) }
        var model = InteractiveReviewModel(categories: [
            CategoryScan(id: "c", title: "C", groups: [ToolGroup(tool: "T", items: items)])
        ])
        model.selectAllMatching()
        model.move(2)
        let buffer = renderReview(model, width: 60, height: 24)
        XCTAssertEqual(buffer[7, 4].style, TextStyle(color: .green))
        XCTAssertEqual(buffer[7, 5].style, TextStyle(color: .yellow))
        XCTAssertEqual(buffer[7, 6].style, TextStyle(inverse: true))
    }

    func testReviewFocusedPathLineSitsBelowDividerAndHintsFollow() {
        let lines = renderReview(InteractiveReviewModel(categories: fixtureCategories()), width: 80, height: 24).plainLines()
        let divider = lines.firstIndex { $0.hasPrefix("├") }!
        XCTAssertTrue(lines[divider].hasSuffix("┤"))
        XCTAssertTrue(lines[divider + 1].hasPrefix("│ Path  /tmp/first"))
        XCTAssertTrue(lines[divider + 2].hasPrefix("│ ↑↓ move  ←→ path  Space toggle  A all  N none  / search  Enter remove"))
        XCTAssertTrue(lines[divider + 3].hasPrefix("│ Esc/q cancel"))
        XCTAssertTrue(lines[23].hasPrefix("╰"))
    }

    func testReviewShowsNoMatchingPathWhenFilterFindsNothing() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.updateQuery("zzz")
        let lines = renderReview(model, width: 80, height: 24).plainLines()
        XCTAssertTrue(lines.contains { $0.hasPrefix("│ Path  No matching item") })
    }

    func testReviewScrollbarStaysInListRowsAndAppearsOnlyWhenRowsOverflow() {
        let fitting = renderReview(InteractiveReviewModel(categories: fixtureCategories()), width: 40, height: 24)
        XCTAssertFalse(fitting.plainLines().contains { $0.contains("┃") })

        var model = InteractiveReviewModel(categories: manyItemsCategories(30))
        model.moveToEnd()
        let lines = renderReview(model, width: 40, height: 12).plainLines()
        let rowsWithThumb = lines.indices.filter { lines[$0].hasSuffix("┃") }
        XCTAssertFalse(rowsWithThumb.isEmpty)
        XCTAssertTrue(rowsWithThumb.allSatisfy { (2...5).contains($0) })
        XCTAssertTrue(rowsWithThumb.contains(5), "thumb is at the bottom when focus is on the last row")
    }

    func testReviewKeepsFocusedRowVisibleAndCentered() {
        var model = InteractiveReviewModel(categories: manyItemsCategories(30))
        model.move(15)
        let lines = renderReview(model, width: 40, height: 12).plainLines()
        XCTAssertTrue(lines[4].hasPrefix("│ › ") && lines[4].contains("/tmp/item15"))
    }

    func testReviewGroupRowKeepsGapBeforeCountWhenToolNameIsLong() {
        let categories = [
            CategoryScan(
                id: "c",
                title: "Cat",
                groups: [
                    ToolGroup(
                        tool: String(repeating: "T", count: 60),
                        items: (0..<12).map { ScanItem(path: "/tmp/i\($0)", sizeBytes: 1, modified: nil) }
                    )
                ]
            )
        ]
        let lines = renderReview(InteractiveReviewModel(categories: categories), width: 40, height: 12).plainLines()
        let group = lines[3]
        XCTAssertTrue(group.contains("…"))
        XCTAssertTrue(group.hasSuffix(" 12 items │"))
        XCTAssertEqual(Term.displayWidth(group), 40)
    }

    func testReviewItemRowTruncatesLongPathInTheMiddle() {
        let path = "/tmp/" + String(repeating: "a", count: 40) + "/" + String(repeating: "b", count: 40) + "/end"
        let categories = [
            CategoryScan(id: "c", title: "Cat", groups: [
                ToolGroup(tool: "Tool", items: [ScanItem(path: path, sizeBytes: 1, modified: nil)])
            ])
        ]
        let line = renderReview(InteractiveReviewModel(categories: categories), width: 40, height: 12).plainLines()[4]
        XCTAssertEqual(Term.displayWidth(line), 40)
        XCTAssertTrue(line.contains("a…"))
        XCTAssertTrue(line.contains("…b") || line.contains("/end"))
        XCTAssertFalse(line.hasSuffix("…│"))
    }

    func testSelectionScreenKeepsTheCyanWindowAndListsEveryItem() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        let buffer = renderReview(model, width: 80, height: 24)
        let lines = buffer.plainLines()
        XCTAssertTrue(lines[0].hasPrefix("╭─ Review removable files "))
        XCTAssertEqual(buffer[0, 0].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[3, 0].style, TextStyle(color: .cyan, bold: true))
        XCTAssertTrue(lines.contains { $0.contains("/tmp/second") })
        XCTAssertTrue(lines.contains { $0.contains("/tmp/third") })
        XCTAssertTrue(lines.contains { $0.contains("Enter remove") })
        XCTAssertFalse(lines.contains { $0.contains("Enter review") || $0.contains("Final review") })
    }

    func testReviewBelowMinimumUsesTooSmallScreen() {
        let model = InteractiveReviewModel(categories: fixtureCategories())
        let buffer = renderReview(model, width: 18, height: 4)
        XCTAssertEqual(buffer, TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: 18, height: 4))
    }

    func testFocusedPathWindowCanRevealEntirePath() {
        let path = "/Users/example/Library/Caches/application/data"
        let first = InteractiveReview.horizontalWindow(path, offset: 0, width: 20)
        let last = InteractiveReview.horizontalWindow(path, offset: 30, width: 20)

        XCTAssertTrue(first.hasSuffix("›"))
        XCTAssertTrue(last.hasPrefix("‹"))
        XCTAssertLessThanOrEqual(Term.displayWidth(first), 20)
        XCTAssertLessThanOrEqual(Term.displayWidth(last), 20)
    }

    func testMenuSelectionClamps() {
        var model = TerminalMenuModel(optionCount: 8)
        model.move(99)
        XCTAssertEqual(model.selection, 7)
        model.move(-99)
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.select(number: 7), 6)
        XCTAssertEqual(model.selection, 6)
        XCTAssertNil(model.select(number: 9))
        XCTAssertNil(model.select(number: 0))
    }

    func testMenuRenderPaginatesAndKeepsHintsVisible() {
        let options = menuOptions(8)
        for (width, height) in [(40, 12), (80, 24)] {
            let lines = renderMenu(options: options, selection: 6, width: width, height: height).plainLines()
            XCTAssertEqual(lines.count, height)
            XCTAssertTrue(lines.contains { $0.contains("Tool 7") })
            XCTAssertTrue(lines.contains { $0.contains("Enter open") })
            XCTAssertTrue(lines.contains { $0.contains("1-9 open") })
            XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == width })
        }
    }

    func testMenuRenderCentersFocusedOptionOnPage() {
        let lines = renderMenu(options: menuOptions(8), selection: 6, width: 40, height: 12).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Tool 6") })
        XCTAssertTrue(lines.contains { $0.contains("Tool 7") })
        XCTAssertFalse(lines.contains { $0.contains("Tool 8") })
        XCTAssertFalse(lines.contains { $0.contains("Tool 5") })
    }

    func testMenuScrollbarTrackStopsAtLastOptionRow() {
        let lines = renderMenu(options: menuOptions(8), selection: 7, width: 40, height: 12).plainLines()
        XCTAssertTrue(lines[6].hasSuffix("┃"), "thumb sits beside the last option detail row")
        XCTAssertFalse(lines[7].hasSuffix("┃"), "spare blank row is not part of the track")
    }

    func testMenuRenderDrawsWindowWithTitleSubtitleAndFocus() {
        let lines = renderMenu(options: menuOptions(2), selection: 0, width: 40, height: 12).plainLines()
        XCTAssertTrue(lines[0].hasPrefix("╭─ PureMac "))
        XCTAssertTrue(lines[0].hasSuffix("─╮"))
        XCTAssertEqual(lines[1], "│ Choose a task" + String(repeating: " ", count: 24) + "│")
        XCTAssertTrue(lines[3].hasPrefix("│ › 1.  Tool 1"))
        XCTAssertTrue(lines[4].hasPrefix("│       Description 1"))
        XCTAssertTrue(lines[5].hasPrefix("│   2.  Tool 2"))
        XCTAssertTrue(lines[8].hasPrefix("├"))
        XCTAssertTrue(lines[8].hasSuffix("┤"))
        XCTAssertTrue(lines[11].hasPrefix("╰"))
        XCTAssertFalse(lines.contains { $0.contains("PUREMAC") })
    }

    func testMenuRenderStylesFocusedRowAndDimsOthers() {
        let colored = renderMenu(options: menuOptions(2), selection: 0, width: 40, height: 12)
            .lines(colors: true)
        XCTAssertTrue(colored[3].contains("\u{1B}[7m"))
        XCTAssertTrue(colored[3].contains("\u{1B}[7;36m›"))
        XCTAssertFalse(colored[5].contains("\u{1B}[7"))
        XCTAssertTrue(colored[6].contains("\u{1B}[2mDescription 2"))
        XCTAssertFalse(colored[4].contains("\u{1B}[2mDescription 1"))
    }

    func testMenuRenderShowsScrollbarOnlyWhenOptionsDoNotFit() {
        let overflowing = renderMenu(options: menuOptions(8), selection: 0, width: 40, height: 12).plainLines()
        XCTAssertTrue(overflowing.contains { $0.hasSuffix("┃") })
        let fitting = renderMenu(options: menuOptions(2), selection: 0, width: 40, height: 12).plainLines()
        XCTAssertFalse(fitting.contains { $0.contains("┃") })
    }

    func testMenuRenderTruncatesLongSubtitleWithEllipsis() {
        let buffer = TerminalMenu.render(
            title: "PureMac",
            subtitle: "Your Mac, with room to work.  /  1.1.1",
            options: menuOptions(2),
            selection: 0,
            width: 40,
            height: 12
        )
        XCTAssertTrue(buffer.plainLines()[1].hasSuffix("…" + " │"))
    }

    func testMenuRenderFocusedRowInverseCoversContentWidthAndDetailIsPlain() {
        let buffer = renderMenu(options: menuOptions(2), selection: 0, width: 40, height: 12)
        XCTAssertTrue(buffer[37, 3].style.inverse)
        XCTAssertFalse(buffer[1, 3].style.inverse)
        XCTAssertEqual(buffer[8, 4].style, .plain)
        XCTAssertEqual(buffer[2, 1].style, TextStyle(dim: true))
    }

    func testMenuNumbersAreCyanExceptOnTheFocusedRow() {
        let buffer = renderMenu(options: menuOptions(2), selection: 0, width: 40, height: 12)
        XCTAssertEqual(buffer[4, 3].symbol, "1")
        XCTAssertEqual(buffer[4, 3].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[4, 5].symbol, "2")
        XCTAssertEqual(buffer[5, 5].symbol, ".")
        XCTAssertEqual(buffer[4, 5].style, TextStyle(color: .cyan))
        XCTAssertEqual(buffer[5, 5].style, TextStyle(color: .cyan))
        XCTAssertEqual(buffer[8, 5].style, .plain)
        XCTAssertEqual(buffer.plainLines()[5], renderMenu(options: menuOptions(2), selection: 1, width: 40, height: 12).plainLines()[5].replacingOccurrences(of: "›", with: " "))
    }

    func testMenuModelStartsAtTheInitialSelectionClamped() {
        XCTAssertEqual(TerminalMenuModel(optionCount: 6, selection: 4).selection, 4)
        XCTAssertEqual(TerminalMenuModel(optionCount: 6, selection: 99).selection, 5)
        XCTAssertEqual(TerminalMenuModel(optionCount: 6, selection: -3).selection, 0)
        XCTAssertEqual(TerminalMenuModel(optionCount: 0, selection: 2).selection, 0)
        XCTAssertEqual(TerminalMenuModel(optionCount: 6).selection, 0)
    }

    func testMenuRenderBelowMinimumUsesTooSmallScreen() {
        let buffer = renderMenu(options: menuOptions(2), selection: 0, width: 30, height: 8)
        XCTAssertEqual(buffer, TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: 30, height: 8))
    }

    func testTooSmallScreenFitsAtMinimumOnly() {
        XCTAssertTrue(TooSmallScreen.fits(width: 40, height: 12))
        XCTAssertFalse(TooSmallScreen.fits(width: 39, height: 12))
        XCTAssertFalse(TooSmallScreen.fits(width: 40, height: 11))
    }

    func testTooSmallScreenRendersCopyTruncatedAndLimited() {
        let lines = TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: 18, height: 4).plainLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 18 })
        XCTAssertTrue(lines[0].hasPrefix("PureMac"))
        XCTAssertTrue(lines[1].hasPrefix("Terminal too small"))
        XCTAssertTrue(lines[2].hasPrefix("Resize to at lea"))
        XCTAssertEqual(lines[3].trimmingCharacters(in: .whitespaces), "")

        let tall = TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: 30, height: 6).plainLines()
        XCTAssertTrue(tall[2].hasPrefix("Resize to at least 40 x 12"))
        XCTAssertTrue(tall[4].hasPrefix("Esc/q cancel"))

        let colored = TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: 30, height: 6)
            .lines(colors: true)
        XCTAssertTrue(colored[0].contains("\u{1B}[1;36mPureMac"))
        XCTAssertTrue(colored[2].contains("\u{1B}[2mResize"))
    }

    func testFocusPointerShowsCyanInverseArrowOnlyWhenFocused() {
        XCTAssertEqual(FocusPointer.span(focused: true), Span("›", TextStyle(color: .cyan, inverse: true)))
        XCTAssertEqual(FocusPointer.span(focused: false), Span(" "))
    }

    func testSizeColumnWidthIsSharedWithPlainOutput() {
        XCTAssertEqual(Term.displayWidth(Render.sizeCol(1_024)), Render.sizeColumnWidth)
    }

    func testConfirmationOpensOnlyWithASelectionAndCancelFocused() {
        var empty = InteractiveReviewModel(categories: fixtureCategories())
        XCTAssertFalse(empty.beginConfirmation())
        XCTAssertFalse(empty.isConfirming)
        XCTAssertEqual(empty.status, "Select at least one item to continue")

        var model = selectedModel()
        XCTAssertFalse(model.isConfirming)
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertTrue(model.isConfirming)
        XCTAssertEqual(model.confirmation, .cancel)
        XCTAssertEqual(model.status, "")
    }

    func testConfirmationFocusMovesWithClamping() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        _ = model.handleConfirmationKey(.left)
        XCTAssertEqual(model.confirmation, .cancel)
        _ = model.handleConfirmationKey(.right)
        XCTAssertEqual(model.confirmation, .remove)
        _ = model.handleConfirmationKey(.right)
        XCTAssertEqual(model.confirmation, .remove)
        _ = model.handleConfirmationKey(.left)
        XCTAssertEqual(model.confirmation, .cancel)
    }

    func testCancelConfirmationReturnsToSelectionAndReopensOnCancel() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        _ = model.handleConfirmationKey(.right)
        model.cancelConfirmation()
        XCTAssertFalse(model.isConfirming)
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.confirmation, .cancel)
    }

    func testEnterRightAfterOpeningOnlyClosesTheDialog() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.handleConfirmationKey(.enter), .handled)
        XCTAssertFalse(model.isConfirming)
    }

    func testEnterOnRemoveConfirms() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.handleConfirmationKey(.right), .handled)
        XCTAssertEqual(model.handleConfirmationKey(.enter), .remove)
    }

    func testTabAndArrowsMoveConfirmationFocus() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.handleConfirmationKey(.tab), .handled)
        XCTAssertEqual(model.confirmation, .remove)
        XCTAssertEqual(model.handleConfirmationKey(.left), .handled)
        XCTAssertEqual(model.confirmation, .cancel)
        XCTAssertEqual(model.handleConfirmationKey(.right), .handled)
        XCTAssertEqual(model.confirmation, .remove)
    }

    func testYConfirmsInOpenDialog() {
        for key in [TerminalKey.character("y"), .character("Y")] {
            var model = selectedModel()
            XCTAssertTrue(model.beginConfirmation())
            XCTAssertEqual(model.handleConfirmationKey(key), .remove)
        }
    }

    func testNAndEscapeCloseTheDialogOnly() {
        for key in [TerminalKey.character("n"), .character("N"), .escape] {
            var model = selectedModel()
            XCTAssertTrue(model.beginConfirmation())
            XCTAssertEqual(model.handleConfirmationKey(key), .handled)
            XCTAssertFalse(model.isConfirming)
        }
    }

    func testQCancelsTheWholeFlowFromTheDialog() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.handleConfirmationKey(.character("q")), .quit)
    }

    func testOtherKeysDoNothingWhileDialogIsOpen() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let before = model.selectedAddresses.count
        let keys: [TerminalKey] = [
            .up, .down, .pageUp, .pageDown, .home, .end, .space, .backspace, .delete, .unknown,
            .character("a"), .character("/"), .character("x")
        ]
        for key in keys {
            XCTAssertEqual(model.handleConfirmationKey(key), .handled)
            XCTAssertTrue(model.isConfirming)
            XCTAssertEqual(model.confirmation, .cancel)
        }
        XCTAssertEqual(model.selectedAddresses.count, before)
    }

    func testConfirmationKeysAreIgnoredWhenDialogIsClosed() {
        var model = selectedModel()
        XCTAssertEqual(model.handleConfirmationKey(.character("y")), .passthrough)
        XCTAssertEqual(model.handleConfirmationKey(.enter), .passthrough)
        XCTAssertEqual(model.handleConfirmationKey(.character("q")), .passthrough)
    }

    func testTabCyclesBetweenButtons() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.handleConfirmationKey(.tab), .handled)
        XCTAssertEqual(model.confirmation, .remove)
        XCTAssertEqual(model.handleConfirmationKey(.tab), .handled)
        XCTAssertEqual(model.confirmation, .cancel)
    }

    func testConfirmationTitleUsesSingularForOneItem() {
        for (count, noun, title) in [(1, "item", "Remove 1 item?"), (1, "artifact", "Remove 1 artifact?"),
                                     (0, "item", "Remove 0 items?"), (2, "artifact", "Remove 2 artifacts?")] {
            XCTAssertEqual(
                InteractiveReview.confirmationDialog(count: count, total: 1_000, hidden: 0, noun: noun, focus: .cancel).title,
                title
            )
        }
    }

    func testConfirmationDialogIsDrawnOverFadedSelectionScreen() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let buffer = renderReview(model, width: 80, height: 24)
        let lines = buffer.plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Remove 2 items?") })
        XCTAssertTrue(lines.contains { $0.contains("3 KB will be deleted") })
        XCTAssertFalse(lines.contains { $0.contains("permanently") || $0.contains("cannot be undone") })
        XCTAssertFalse(lines.contains { $0.contains("hidden by search") })
        XCTAssertTrue(lines.contains { $0.contains("› Cancel ‹  [ Remove ]") })
        XCTAssertTrue(lines.contains { $0.contains("Enter select  Esc back") })
        XCTAssertFalse(lines.contains { $0.contains("Y remove") || $0.contains("choose") })
        XCTAssertTrue(lines.contains { $0.contains("/tmp/first") })
        XCTAssertTrue(lines.contains { $0.contains("/tmp/second") })
        XCTAssertTrue(lines.contains { $0.contains("/tmp/thir") })
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 80 })
        XCTAssertEqual(buffer[0, 0].style, TextStyle(dim: true))
        XCTAssertEqual(buffer[3, 0].style, TextStyle(dim: true))
    }

    func testConfirmationDialogUsesYellowTitleAndBorder() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let buffer = renderReview(model, width: 80, height: 24)
        let frame = InteractiveReview.confirmationDialog(count: 2, total: 3_000, hidden: 0, noun: "item", focus: .cancel)
            .frame(in: buffer.area)
        XCTAssertEqual(buffer[frame.x, frame.y].style, TextStyle(color: .yellow))
        XCTAssertEqual(buffer[frame.x + 3, frame.y].style, TextStyle(color: .yellow, bold: true))
    }

    func testConfirmationDialogFocusStyles() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let cancelFocused = renderReview(model, width: 80, height: 24).lines(colors: true).joined()
        XCTAssertTrue(cancelFocused.contains("\u{1B}[7m› Cancel ‹"))
        XCTAssertTrue(cancelFocused.contains("\u{1B}[31m[ Remove ]"))

        _ = model.handleConfirmationKey(.right)
        let removeFocused = renderReview(model, width: 80, height: 24).lines(colors: true).joined()
        XCTAssertTrue(removeFocused.contains("\u{1B}[7;31m› Remove ‹"))
        XCTAssertFalse(removeFocused.contains("\u{1B}[7m› Cancel ‹"))
    }

    func testConfirmationDialogUsesTheGivenNoun() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let lines = InteractiveReview.render(
            model: model, title: "Choose project artifacts", noun: "artifact", width: 80, height: 24
        ).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Remove 2 artifacts?") })
    }

    func testConfirmationDialogFitsMinimumSize() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        let lines = renderReview(model, width: 40, height: 12).plainLines()
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines.contains { $0.contains("› Cancel ‹  [ Remove ]") })
        XCTAssertTrue(lines.contains { $0.contains("Enter select  Esc back") })
    }

    func testHiddenSelectedCountIsTheSelectedItemsTheSearchFiltersOut() {
        var model = selectedModel()
        XCTAssertEqual(model.hiddenSelectedCount, 0)
        model.updateQuery("second")
        XCTAssertEqual(model.hiddenSelectedCount, 1)
        XCTAssertEqual(model.selectedCount, 2)
        model.updateQuery("zzz")
        XCTAssertEqual(model.hiddenSelectedCount, 2)
        model.updateQuery("/tmp")
        XCTAssertEqual(model.hiddenSelectedCount, 0)
    }

    func testSearchDoesNotNarrowWhatTheConfirmationCountsAndRemoves() {
        var model = selectedModel()
        model.updateQuery("second")
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.selectedResult().flatMap { $0.selectedItems }.map(\.path), ["/tmp/first", "/tmp/second"])
        let lines = renderReview(model, width: 80, height: 24).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Remove 2 items?") })
        XCTAssertTrue(lines.contains { $0.contains("3 KB will be deleted") })
    }

    func testHiddenBySearchRowAppearsDimOnlyWhenSelectedItemsAreFilteredOut() {
        var model = selectedModel()
        model.updateQuery("second")
        XCTAssertTrue(model.beginConfirmation())
        let buffer = renderReview(model, width: 80, height: 24)
        let lines = buffer.plainLines()
        let row = lines.firstIndex { $0.contains("1 hidden by search") }!
        let column = lines[row].distance(from: lines[row].startIndex, to: lines[row].range(of: "1 hidden")!.lowerBound)
        XCTAssertEqual(buffer[column, row].style, TextStyle(dim: true))
        XCTAssertTrue(lines[row - 1].contains("3 KB will be deleted"))

        model.cancelConfirmation()
        model.updateQuery("/tmp")
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertFalse(renderReview(model, width: 80, height: 24).plainLines().contains { $0.contains("hidden by search") })
    }

    func testConfirmationDialogFitsMinimumSizeWithHiddenRow() {
        var model = selectedModel()
        model.updateQuery("second")
        XCTAssertTrue(model.beginConfirmation())
        let lines = renderReview(model, width: 40, height: 12).plainLines()
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines.contains { $0.contains("1 hidden by search") })
        XCTAssertTrue(lines.contains { $0.contains("› Cancel ‹  [ Remove ]") })
    }

    func testSelectionWithoutDialogIsNotFaded() {
        let buffer = renderReview(selectedModel(), width: 80, height: 24)
        XCTAssertEqual(buffer[3, 0].style, TextStyle(color: .cyan, bold: true))
        XCTAssertFalse(buffer.plainLines().contains { $0.contains("Cancel") })
    }

    func testEnterOnTheSelectionOpensDialogAndNeverReturnsTheSelection() {
        var model = selectedModel()
        XCTAssertEqual(model.routeKey(.enter), .handled)
        XCTAssertTrue(model.isConfirming)
        XCTAssertEqual(model.confirmation, .cancel)
        XCTAssertEqual(model.routeKey(.enter), .handled)
        XCTAssertFalse(model.isConfirming)
    }

    func testEnterWithNothingSelectedIsHandledWithoutOpeningTheDialog() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        XCTAssertEqual(model.routeKey(.enter), .handled)
        XCTAssertFalse(model.isConfirming)
        XCTAssertEqual(model.status, "Select at least one item to continue")
    }

    func testRouteKeyReturnsRemoveOnlyFromTheOpenDialog() {
        var model = selectedModel()
        XCTAssertEqual(model.routeKey(.character("y")), .passthrough)
        XCTAssertTrue(model.beginConfirmation())
        XCTAssertEqual(model.routeKey(.character("y")), .remove)
        XCTAssertEqual(model.routeKey(.character("q")), .quit)
        XCTAssertEqual(model.routeKey(.space), .handled)
    }

    func testEnterWhileSearchingPassesThroughAndOpensNoDialog() {
        var model = selectedModel()
        model.isSearching = true
        XCTAssertEqual(model.routeKey(.enter), .passthrough)
        XCTAssertFalse(model.isConfirming)
    }

    func testTooSmallScreenLetsOnlyCloseAndCancelKeysReachTheDialog() {
        var model = selectedModel()
        XCTAssertTrue(model.beginConfirmation())
        for key in [TerminalKey.escape, .character("n"), .character("N"), .character("q"), .enter] {
            XCTAssertTrue(model.acceptsKey(key, tooSmall: true), "\(key)")
        }
        for key in [TerminalKey.character("y"), .character("Y"), .tab, .right, .space, .left] {
            XCTAssertFalse(model.acceptsKey(key, tooSmall: true), "\(key)")
        }
        _ = model.handleConfirmationKey(.right)
        XCTAssertFalse(model.acceptsKey(.enter, tooSmall: true))
        XCTAssertTrue(model.acceptsKey(.character("y"), tooSmall: false))
    }

    func testTooSmallRuleDoesNotAffectOtherStates() {
        let model = selectedModel()
        XCTAssertTrue(model.acceptsKey(.enter, tooSmall: true))
        XCTAssertTrue(model.acceptsKey(.down, tooSmall: true))
    }

    private func selectedModel() -> InteractiveReviewModel {
        .selected(fixtureCategories(), selecting: [0, 1])
    }

    private func menuOptions(_ count: Int) -> [(title: String, detail: String)] {
        (1...count).map { (title: "Tool \($0)", detail: "Description \($0)") }
    }

    private func renderMenu(
        options: [(title: String, detail: String)],
        selection: Int,
        width: Int,
        height: Int
    ) -> Buffer {
        TerminalMenu.render(
            title: "PureMac",
            subtitle: "Choose a task",
            options: options,
            selection: selection,
            width: width,
            height: height
        )
    }

    private func renderReview(_ model: InteractiveReviewModel, width: Int, height: Int) -> Buffer {
        InteractiveReview.render(model: model, title: "Review removable files", noun: "item", width: width, height: height)
    }

    private func manyItemsCategories(_ count: Int) -> [CategoryScan] {
        [
            CategoryScan(
                id: "many",
                title: "Many",
                groups: [
                    ToolGroup(
                        tool: "Items",
                        items: (0..<count).map { ScanItem(path: "/tmp/item\($0)", sizeBytes: 1_000, modified: nil) }
                    )
                ]
            )
        ]
    }

    private func fixtureCategories() -> [CategoryScan] {
        [
            CategoryScan(
                id: "dev",
                title: "Developer",
                groups: [
                    ToolGroup(
                        tool: "Build caches",
                        items: [
                            ScanItem(path: "/tmp/first", sizeBytes: 1_000, modified: nil, selected: true),
                            ScanItem(path: "/tmp/second", sizeBytes: 2_000, modified: nil, selected: true)
                        ]
                    ),
                    ToolGroup(
                        tool: "Package caches",
                        items: [
                            ScanItem(path: "/tmp/third", sizeBytes: 3_000, modified: nil, selected: false)
                        ]
                    )
                ]
            )
        ]
    }
}
