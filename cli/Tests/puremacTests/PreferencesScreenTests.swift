import Foundation
import XCTest
@testable import puremac
import TerminalUI

private struct Broken: LocalizedError {
    var errorDescription: String? { "disk is full" }
}

final class PreferencesScreenTests: XCTestCase {
    private func savedDays() throws -> Int {
        try ConfigStore(fileURL: AppPaths.configFile).olderThanDays
    }

    private func setDays(_ days: Int) throws {
        var store = try ConfigStore(fileURL: AppPaths.configFile)
        try store.set(ConfigStore.daysKey, String(days))
    }

    private func lines(_ screen: PreferencesScreen, width: Int = 160, height: Int = 24) -> [String] {
        screen.render(width: width, height: height).plainLines()
    }

    func testStartsWithTheStoredValuesAndTheAgeRowFocused() throws {
        try withConfigHome { _ in
            let screen = PreferencesScreen()
            XCTAssertEqual(screen.days, 7)
            XCTAssertEqual(screen.folderCount, Purger.defaultRoots.count)
            XCTAssertEqual(screen.pathCount, 0)
            XCTAssertEqual(screen.focus, .age)
        }
    }

    func testRightAndLeftStepThroughThePresetsAndSaveImmediately() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            XCTAssertNil(screen.handle(.right))
            XCTAssertEqual(screen.days, 14)
            XCTAssertEqual(try savedDays(), 14)
            _ = screen.handle(.left)
            _ = screen.handle(.left)
            XCTAssertEqual(screen.days, 3)
            XCTAssertEqual(try savedDays(), 3)
        }
    }

    func testPresetsStopAtBothEnds() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            for _ in 0..<12 { _ = screen.handle(.left) }
            XCTAssertEqual(screen.days, 1)
            for _ in 0..<12 { _ = screen.handle(.right) }
            XCTAssertEqual(screen.days, 365)
            XCTAssertEqual(try savedDays(), 365)
        }
    }

    func testAValueBetweenPresetsMovesToTheNearestPresetInThatDirection() throws {
        try withConfigHome { _ in
            try setDays(10)
            var right = PreferencesScreen()
            _ = right.handle(.right)
            XCTAssertEqual(right.days, 14)
            var left = PreferencesScreen()
            _ = left.handle(.left)
            XCTAssertEqual(left.days, 7)
            try setDays(1000)
            var past = PreferencesScreen()
            _ = past.handle(.right)
            XCTAssertEqual(past.days, 1000)
            _ = past.handle(.left)
            XCTAssertEqual(past.days, 365)
        }
    }

    func testUpAndDownMoveBetweenTheThreeRowsAndStopAtTheEnds() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            _ = screen.handle(.up)
            XCTAssertEqual(screen.focus, .age)
            _ = screen.handle(.down)
            XCTAssertEqual(screen.focus, .projectFolders)
            _ = screen.handle(.down)
            _ = screen.handle(.down)
            XCTAssertEqual(screen.focus, .protectedPaths)
            _ = screen.handle(.up)
            XCTAssertEqual(screen.focus, .projectFolders)
        }
    }

    func testLeftAndRightChangeNothingOnTheListRows() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            _ = screen.handle(.down)
            XCTAssertNil(screen.handle(.right))
            XCTAssertNil(screen.handle(.left))
            XCTAssertEqual(screen.days, 7)
            XCTAssertEqual(screen.focus, .projectFolders)
        }
    }

    func testEnterOpensTheEditorsAndDoesNothingOnTheAgeRow() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            XCTAssertNil(screen.handle(.enter))
            _ = screen.handle(.down)
            XCTAssertEqual(screen.handle(.enter), .openProjectFolders)
            _ = screen.handle(.down)
            XCTAssertEqual(screen.handle(.enter), .openProtectedPaths)
        }
    }

    func testEscapeAndQGoBack() throws {
        try withConfigHome { _ in
            for key in [TerminalKey.escape, .character("q"), .character("Q")] {
                var screen = PreferencesScreen()
                XCTAssertEqual(screen.handle(key), .back, "\(key)")
            }
            var screen = PreferencesScreen()
            XCTAssertNil(screen.handle(.character("x")))
        }
    }

    func testReloadPicksUpChangesMadeInTheEditors() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen()
            var ignore = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            _ = try ignore.add("/tmp/puremac-a")
            try Data("/tmp/puremac-x\n".utf8).write(to: AppPaths.projectsFile)
            screen.reload()
            XCTAssertEqual(screen.pathCount, 1)
            XCTAssertEqual(screen.folderCount, 1)
        }
    }

    func testRendersTitleSectionsRowsAndHints() throws {
        try withConfigHome { dir in
            let rows = lines(PreferencesScreen())
            let text = rows.joined(separator: "\n")
            XCTAssertTrue(rows[0].contains("Preferences"), rows[0])
            XCTAssertTrue(rows[1].hasPrefix("│ Project cleanup"), rows[1])
            XCTAssertTrue(rows[2].hasPrefix("│ › Preselect artifacts older than  ‹ 7 days ›"), rows[2])
            XCTAssertTrue(rows[3].hasPrefix("│   Project folders"), rows[3])
            XCTAssertTrue(rows[3].contains("\(Purger.defaultRoots.count) folders ›"), rows[3])
            XCTAssertTrue(rows[5].hasPrefix("│ Protection"), rows[5])
            XCTAssertTrue(rows[6].hasPrefix("│   Protected paths"), rows[6])
            XCTAssertTrue(rows[6].contains("0 paths ›"), rows[6])
            XCTAssertTrue(text.contains("Saved in \(Render.shorten(dir.path))"), text)
            XCTAssertTrue(rows[22].contains("↑↓ move  ←→ change  Enter open  Esc back"), rows[22])
        }
    }

    func testSingularCounts() throws {
        try withConfigHome { _ in
            var ignore = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            _ = try ignore.add("/tmp/puremac-a")
            var store = try ConfigStore(fileURL: AppPaths.configFile)
            try Data("/tmp/puremac-x\n".utf8).write(to: AppPaths.projectsFile)
            try store.set(ConfigStore.daysKey, "1")
            let text = lines(PreferencesScreen()).joined(separator: "\n")
            XCTAssertTrue(text.contains("‹ 1 day ›"), text)
            XCTAssertTrue(text.contains("1 folder ›"), text)
            XCTAssertTrue(text.contains("1 path ›"), text)
        }
    }

    func testFocusedRowIsInverseWithACyanPointer() throws {
        try withConfigHome { _ in
            let buffer = PreferencesScreen().render(width: 80, height: 24)
            XCTAssertEqual(buffer[2, 2].style, TextStyle(color: .cyan, inverse: true))
            XCTAssertEqual(buffer[4, 2].style, TextStyle(inverse: true))
            XCTAssertEqual(buffer[4, 3].style, .plain)
        }
    }

    func testSavedInRowIsDimAboveTheDivider() throws {
        try withConfigHome { _ in
            let buffer = PreferencesScreen().render(width: 160, height: 24)
            let rows = buffer.plainLines()
            XCTAssertTrue(rows[20].hasPrefix("│ Saved in "), rows[20])
            XCTAssertTrue(rows[21].hasPrefix("├"), rows[21])
            XCTAssertEqual(buffer[2, 20].style, TextStyle(dim: true))
        }
    }

    func testSetupErrorShowsAsAYellowRow() throws {
        try withConfigHome { _ in
            let buffer = PreferencesScreen(setupError: Broken()).render(width: 160, height: 24)
            let rows = buffer.plainLines()
            let index = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("│ Could not create settings files: disk is full") })
            XCTAssertEqual(buffer[2, index].style, TextStyle(color: .yellow))
            XCTAssertFalse(lines(PreferencesScreen()).joined().contains("Could not create"))
        }
    }

    func testSetupErrorStaysAfterKeysAndReload() throws {
        try withConfigHome { _ in
            var screen = PreferencesScreen(setupError: Broken())
            _ = screen.handle(.right)
            _ = screen.handle(.down)
            screen.reload()
            XCTAssertTrue(lines(screen).joined().contains("Could not create settings files: disk is full"))
        }
    }

    func testUnreadableConfigShowsARedRowInsteadOfFailing() throws {
        try withConfigHome { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: AppPaths.configFile)
            let screen = PreferencesScreen()
            let buffer = screen.render(width: 160, height: 24)
            let rows = buffer.plainLines()
            let index = try XCTUnwrap(rows.firstIndex { $0.contains("not a valid") })
            XCTAssertEqual(buffer[2, index].style, TextStyle(color: .red))
            XCTAssertEqual(screen.days, ConfigStore.defaultDays)
        }
    }

    func testUnreadableProjectsFileShowsARedRowAndKeepsTheDefaultCount() throws {
        try withConfigHome { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("relative\n".utf8).write(to: AppPaths.projectsFile)
            let screen = PreferencesScreen()
            let buffer = screen.render(width: 160, height: 24)
            let rows = buffer.plainLines()
            let index = try XCTUnwrap(rows.firstIndex { $0.contains("Project folders file contains an invalid or relative path") })
            XCTAssertEqual(buffer[2, index].style, TextStyle(color: .red))
            XCTAssertEqual(screen.folderCount, Purger.defaultRoots.count)
            XCTAssertEqual(screen.days, 7)
        }
    }

    func testFailedSaveShowsAYellowRowUntilTheNextKey() throws {
        try withConfigHome { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: AppPaths.configFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            var screen = PreferencesScreen()
            _ = screen.handle(.right)
            XCTAssertEqual(screen.days, 7)
            let buffer = screen.render(width: 160, height: 24)
            let rows = buffer.plainLines()
            let index = try XCTUnwrap(rows.firstIndex { $0.contains("permission") })
            XCTAssertEqual(buffer[2, index].style, TextStyle(color: .yellow))
            _ = screen.handle(.down)
            XCTAssertFalse(lines(screen).joined().contains("permission"))
        }
    }

    func testSetupErrorNeverHidesTheListRowsInSmallWindows() throws {
        try withConfigHome { _ in
            for size in [(80, 12), (40, 12)] {
                var screen = PreferencesScreen(setupError: Broken())
                _ = screen.handle(.down)
                _ = screen.handle(.down)
                XCTAssertEqual(screen.focus, .protectedPaths)
                let rows = lines(screen, width: size.0, height: size.1)
                for label in ["Project cleanup", "Preselect", "Project folders", "Protection", "Protected paths"] {
                    XCTAssertTrue(rows.contains { $0.contains(label) }, "\(label) at \(size): \(rows)")
                }
            }
        }
    }

    func testErrorTakesTheSavedInRowWhenThereIsNoRoomBelowTheList() throws {
        try withConfigHome { _ in
            let buffer = PreferencesScreen(setupError: Broken()).render(width: 40, height: 12)
            let rows = buffer.plainLines()
            let index = try XCTUnwrap(rows.firstIndex { $0.contains("Could not create") }, "\(rows)")
            XCTAssertEqual(buffer[2, index].style, TextStyle(color: .yellow))
            XCTAssertFalse(rows.joined().contains("Saved in"))
        }
    }

    func testValuesStayInOneColumnWhenTheWindowIsNarrow() throws {
        try withConfigHome { _ in
            func start(of value: String, in rows: [String]) -> Int? {
                rows.compactMap { row in
                    row.range(of: value).map { row.distance(from: row.startIndex, to: $0.lowerBound) }
                }.first
            }
            var columns: [[Int?]] = []
            var labels: [String] = []
            for days in [7, 365] {
                try setDays(days)
                let rows = lines(PreferencesScreen(), width: 40, height: 12)
                columns.append([
                    start(of: "‹ \(days) days ›", in: rows),
                    start(of: "\(Purger.defaultRoots.count) folders ›", in: rows),
                    start(of: "0 paths ›", in: rows),
                ])
                labels.append(String(rows[2].prefix { $0 != "‹" }))
            }
            for set in columns { XCTAssertEqual(Set(set.map { $0 ?? -1 }).count, 1, "\(columns)") }
            XCTAssertNotNil(columns[0][0])
            XCTAssertEqual(columns[0], columns[1])
            XCTAssertEqual(labels[0], labels[1])
        }
    }

    func testUnreadableConfigShowsTheErrorOnceWhenChangingDays() throws {
        try withConfigHome { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: AppPaths.configFile)
            var screen = PreferencesScreen()
            _ = screen.handle(.right)
            let text = lines(screen).joined(separator: "\n")
            XCTAssertEqual(text.components(separatedBy: "not a valid").count - 1, 1, text)
        }
    }

    func testLongConfigPathIsShortenedWithAMiddleEllipsis() throws {
        try withConfigHome { _ in
            let rows = lines(PreferencesScreen(), width: 50)
            XCTAssertTrue(rows[20].contains("…"), rows[20])
            XCTAssertTrue(rows[20].hasSuffix(" │"), rows[20])
        }
    }

    func testNarrowWindowKeepsRowsInsideTheFrame() throws {
        try withConfigHome { _ in
            for row in lines(PreferencesScreen(), width: 40, height: 12) {
                XCTAssertEqual(Term.displayWidth(row), 40, row)
            }
            let rows = lines(PreferencesScreen(), width: 40, height: 12)
            XCTAssertTrue(rows[2].contains("‹ 7 days ›"), rows[2])
        }
    }

    func testTooSmallTerminalShowsTheTooSmallScreenAndAcceptsOnlyEscape() throws {
        try withConfigHome { _ in
            let screen = PreferencesScreen()
            let text = lines(screen, width: 39, height: 24).joined(separator: "\n")
            XCTAssertTrue(text.contains("Terminal too small"), text)
            XCTAssertTrue(text.contains("Esc back"), text)
            XCTAssertTrue(screen.acceptsKey(.escape, tooSmall: true))
            for key in [TerminalKey.right, .enter, .down, .character("q")] {
                XCTAssertFalse(screen.acceptsKey(key, tooSmall: true), "\(key)")
                XCTAssertTrue(screen.acceptsKey(key, tooSmall: false), "\(key)")
            }
        }
    }
}
