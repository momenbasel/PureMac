import XCTest
import TerminalUI
@testable import puremac

final class StartConfirmationTests: XCTestCase {
    func testEnterActivatesTheFocusedButton() {
        var model = StartConfirmation.explore
        XCTAssertEqual(model.handle(.enter), .start)
        XCTAssertNil(model.handle(.left))
        XCTAssertEqual(model.handle(.enter), .back)
    }

    func testLeftRightClampAndTabCycles() {
        var model = StartConfirmation.explore
        XCTAssertNil(model.handle(.right))
        XCTAssertEqual(model.handle(.enter), .start)
        XCTAssertNil(model.handle(.left))
        XCTAssertNil(model.handle(.left))
        XCTAssertEqual(model.handle(.enter), .back)
        XCTAssertNil(model.handle(.tab))
        XCTAssertEqual(model.handle(.enter), .start)
        XCTAssertNil(model.handle(.tab))
        XCTAssertEqual(model.handle(.enter), .back)
    }

    func testEscapeQAndNGoBackFromAnyFocus() {
        for key in [TerminalKey.escape, .character("q"), .character("Q"), .character("n"), .character("N")] {
            var model = StartConfirmation.explore
            XCTAssertEqual(model.handle(key), .back)
        }
    }

    func testSStartsFromAnyFocus() {
        var model = StartConfirmation.explore
        _ = model.handle(.left)
        XCTAssertEqual(model.handle(.character("s")), .start)
        XCTAssertEqual(model.handle(.character("S")), .start)
    }

    func testTooSmallScreenAcceptsOnlyEscapeQAndN() {
        let model = StartConfirmation.explore
        for key in [TerminalKey.escape, .character("q"), .character("Q"), .character("n"), .character("N")] {
            XCTAssertTrue(model.acceptsKey(key, tooSmall: true))
        }
        for key in [TerminalKey.enter, .character("s"), .character("S"), .left, .right, .tab, .space] {
            XCTAssertFalse(model.acceptsKey(key, tooSmall: true))
            XCTAssertTrue(model.acceptsKey(key, tooSmall: false))
        }
    }

    func testOtherKeysDoNothing() {
        var model = StartConfirmation.explore
        for key in [TerminalKey.up, .down, .space, .character("x"), .character("y")] {
            XCTAssertNil(model.handle(key))
        }
        XCTAssertEqual(model.handle(.enter), .start)
    }

    func testRendersTheDialogOverTheFadedMenu() {
        let buffer = StartConfirmation.explore.render(width: 80, height: 24)
        let lines = buffer.plainLines()
        XCTAssertEqual(lines.count, 24)
        XCTAssertTrue(lines.contains { $0.contains("Explore your home folder?") })
        XCTAssertTrue(lines.contains { $0.contains("Measuring every folder can take a few minutes.") })
        XCTAssertTrue(lines.contains { $0.contains("[ Cancel ]  › Start ‹") })
        XCTAssertTrue(lines.contains { $0.contains("Enter select  Esc back") })
        let menuRow = lines.firstIndex { $0.contains("Clean caches") }
        XCTAssertNotNil(menuRow)
        XCTAssertEqual(buffer[2, menuRow ?? 0].style, TextStyle(dim: true))
    }

    func testFocusFollowsTheModel() {
        var model = StartConfirmation.explore
        _ = model.handle(.left)
        let lines = model.render(width: 80, height: 24).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("› Cancel ‹  [ Start ]") })
    }

    func testFitsTheMinimumSize() {
        let lines = StartConfirmation.explore.render(width: 40, height: 12).plainLines()
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines.contains { $0.contains("Enter select  Esc back") })
    }

    func testBelowTheMinimumSizeShowsWhatEscDoes() {
        let lines = StartConfirmation.explore.render(width: 39, height: 11).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Esc back") })
    }

    func testProjectCleanupDialogTitleMessageAndFocus() {
        let lines = StartConfirmation.projectCleanup(folderCount: 3).render(width: 80, height: 24).plainLines()
        XCTAssertTrue(lines.contains { $0.contains("Scan your project folders?") })
        XCTAssertTrue(lines.contains { $0.contains("Searching 3 folders for build artifacts can take a few") })
        XCTAssertTrue(lines.contains { $0.contains("[ Cancel ]  › Start ‹") })
        XCTAssertTrue(lines.contains { $0.contains("Enter select  Esc back") })
        XCTAssertTrue(lines.contains { $0.contains("Project cleanup") })
    }

    func testProjectCleanupMessageWrapsWithoutAnOrphanWord() {
        let model = StartConfirmation.projectCleanup(folderCount: 1)
        for (width, height) in [(64, 18), (40, 12)] {
            let lines = model.render(width: width, height: height).plainLines()
            let rows = lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╮╰╯─ ")) }
            XCTAssertFalse(rows.contains("minutes."), "\(width)x\(height)")
        }
        let wide = model.render(width: 64, height: 18).plainLines().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╮╰╯─ ")) }
        XCTAssertTrue(wide.contains("Searching 1 folder for build"))
        XCTAssertTrue(wide.contains("artifacts can take a few minutes."))
        let narrow = model.render(width: 40, height: 12).plainLines().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╮╰╯─ ")) }
        XCTAssertTrue(narrow.contains("take a few minutes."))
    }

    func testProjectCleanupMessageUsesTheSingularForOneFolder() {
        let message = StartConfirmation.projectCleanup(folderCount: 1).message
        XCTAssertEqual(message, "Searching 1 folder for build artifacts can take a few minutes.")
        XCTAssertEqual(
            StartConfirmation.projectCleanup(folderCount: 5).message,
            "Searching 5 folders for build artifacts can take a few minutes."
        )
    }

    func testProjectCleanupKeysMatchTheExplorerDialog() {
        var model = StartConfirmation.projectCleanup(folderCount: 2)
        XCTAssertEqual(model.handle(.character("s")), .start)
        XCTAssertEqual(model.handle(.escape), .back)
        XCTAssertNil(model.handle(.left))
        XCTAssertEqual(model.handle(.enter), .back)
    }

    func testBackgroundMenuFocusFollowsTheEntry() {
        let explore = StartConfirmation.explore.render(width: 80, height: 24).plainLines()
        let project = StartConfirmation.projectCleanup(folderCount: 2).render(width: 80, height: 24).plainLines()
        XCTAssertTrue(explore.contains { $0.contains("› 3.  Explor") })
        XCTAssertTrue(project.contains { $0.contains("› 2.  Project cleanup") })
    }

    func testProjectCleanupEntryAsksWhenFoldersExist() {
        guard case .confirm(let confirmation) = HomeMenu.projectCleanupEntry(folderCount: { 2 }) else {
            return XCTFail("expected a confirmation")
        }
        XCTAssertTrue(confirmation.message.contains("2 folders"))
    }

    func testProjectCleanupEntryShowsTheNoFoldersNoticeWithoutFolders() {
        guard case .notice(let message) = HomeMenu.projectCleanupEntry(folderCount: { 0 }) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(message, Purge.noFoldersMessage)
    }

    func testProjectCleanupEntryTurnsAnInvalidProjectsFileIntoANotice() {
        let error = StoreError.invalidProjectsFile("/tmp/projects")
        guard case .notice(let message) = HomeMenu.projectCleanupEntry(folderCount: { throw error }) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(message, error.localizedDescription)
    }

    func testNoticeShowsTheMessageInAnInfoDialogOverTheFadedMenu() {
        let buffer = HomeMenu.projectCleanupNotice(message: Purge.noFoldersMessage, width: 80, height: 24)
        let lines = buffer.plainLines()
        XCTAssertTrue(lines.contains { $0.contains("No project folders configured. Add one in Preferences.") })
        XCTAssertTrue(lines.contains { $0.contains("› OK ‹") })
        XCTAssertTrue(lines.contains { $0.contains("Project cleanup") })
        XCTAssertEqual(buffer[0, 0].style, TextStyle(dim: true))
    }

    func testNoticeWithALongErrorWrapsInsideTheDialog() {
        let message = StoreError.invalidProjectsFile("/Users/example/.config/puremac/projects").localizedDescription
        let lines = HomeMenu.projectCleanupNotice(message: message, width: 40, height: 12).plainLines()
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines.contains { $0.contains("› OK ‹") })
    }
}
