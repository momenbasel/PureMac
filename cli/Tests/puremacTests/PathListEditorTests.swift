import XCTest
@testable import puremac
import TerminalUI

private struct Rejected: LocalizedError {
    var errorDescription: String? { "that path is not allowed" }
}

private final class FakeList {
    var paths: [String]
    var added: [String] = []
    var removed: [String] = []
    var addError: Error?
    var loadError: Error?
    var sorted = false

    init(_ paths: [String]) { self.paths = paths }

    func config(confirmsRemoval: Bool = false) -> PathListConfig {
        PathListConfig(
            title: "Project folders",
            emptyText: "Nothing here yet. Press A to add one.",
            load: {
                if let error = self.loadError { throw error }
                return self.paths
            },
            add: { path in
                if let error = self.addError { throw error }
                self.added.append(path)
                self.paths.append(path)
                if self.sorted { self.paths.sort() }
            },
            remove: { path in
                self.removed.append(path)
                self.paths.removeAll { $0 == path }
            },
            removalPrompt: confirmsRemoval
                ? RemovalPrompt(title: { "Stop protecting \($0)?" }, button: "Remove protection")
                : nil
        )
    }
}

final class PathListEditorTests: XCTestCase {
    private let existing = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path

    private func editor(_ list: FakeList, confirmsRemoval: Bool = false) -> PathListEditor {
        PathListEditor(list.config(confirmsRemoval: confirmsRemoval))
    }

    private func type(_ text: String, into editor: inout PathListEditor) {
        for character in text { _ = editor.handle(character == " " ? .space : .character(character)) }
    }

    private func lines(_ editor: PathListEditor, width: Int = 80, height: Int = 24) -> [String] {
        editor.render(width: width, height: height).plainLines()
    }

    func testStartsWithLoadedPathsAndFirstFocused() {
        let editor = editor(FakeList([existing, "/tmp/puremac-b"]))
        XCTAssertEqual(editor.paths, [existing, "/tmp/puremac-b"])
        XCTAssertEqual(editor.focus, 0)
    }

    func testMovingStaysInsideTheList() {
        var editor = editor(FakeList(["/a", "/b"]))
        _ = editor.handle(.up)
        XCTAssertEqual(editor.focus, 0)
        _ = editor.handle(.down)
        _ = editor.handle(.down)
        XCTAssertEqual(editor.focus, 1)
    }

    func testEscapeLeavesAndOtherKeysDoNot() {
        var editor = editor(FakeList(["/a"]))
        XCTAssertFalse(editor.handle(.down))
        XCTAssertFalse(editor.handle(.character("x")))
        XCTAssertTrue(editor.handle(.escape))
    }

    func testProjectFoldersLabelTheInputAddFolderAndProtectedPathsAddPath() throws {
        XCTAssertEqual(PathListConfig.projectFolders.inputLabel, "Add folder")
        XCTAssertEqual(PathListConfig.protectedPaths.inputLabel, "Add path")
        var config = FakeList([]).config()
        config.inputLabel = "Add path"
        var editor = PathListEditor(config)
        _ = editor.handle(.character("a"))
        XCTAssertTrue(lines(editor)[21].hasPrefix("│ Add path  ~/ "), lines(editor)[21])
    }

    func testFocusMovesToTheNewEntryAfterAnAdd() {
        let list = FakeList(["/b", "/d"])
        list.sorted = true
        var editor = editor(list)
        _ = editor.handle(.character("a"))
        for _ in 0..<2 { _ = editor.handle(.backspace) }
        type("/c", into: &editor)
        _ = editor.handle(.enter)
        XCTAssertEqual(editor.paths, ["/b", "/c", "/d"])
        XCTAssertEqual(editor.focus, 1)
    }

    func testFocusMovesToTheEndWhenTheNewEntryIsAppended() {
        var editor = editor(FakeList(["/a", "/b"]))
        _ = editor.handle(.character("a"))
        type("x", into: &editor)
        _ = editor.handle(.enter)
        XCTAssertEqual(editor.focus, 2)
    }

    func testFocusStaysWhenAnAddFails() {
        let list = FakeList(["/a", "/b"])
        list.addError = Rejected()
        var editor = editor(list)
        _ = editor.handle(.down)
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        XCTAssertEqual(editor.focus, 1)
    }

    func testProtectedPathsFocusFollowsTheSortedPosition() throws {
        try withConfigHome { _ in
            var store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
            _ = try store.add("/tmp/puremac-a")
            _ = try store.add("/tmp/puremac-c")
            var editor = PathListEditor(.protectedPaths)
            _ = editor.handle(.character("a"))
            for _ in 0..<2 { _ = editor.handle(.backspace) }
            type("/tmp/puremac-b", into: &editor)
            _ = editor.handle(.enter)
            XCTAssertEqual(editor.paths, ["/tmp/puremac-a", "/tmp/puremac-b", "/tmp/puremac-c"])
            XCTAssertEqual(editor.focus, 1)
        }
    }

    func testAOpensTheInputPrefilledWithTilde() {
        var editor = editor(FakeList([]))
        _ = editor.handle(.character("a"))
        XCTAssertEqual(editor.input?.text, "~/")
        var other = self.editor(FakeList([]))
        _ = other.handle(.character("A"))
        XCTAssertEqual(other.input?.text, "~/")
    }

    func testInputRowShowsLabelTextAndInverseCursorBelowTheStatusRow() {
        var editor = editor(FakeList(["/a"]))
        _ = editor.handle(.character("a"))
        type("pr", into: &editor)
        let buffer = editor.render(width: 80, height: 24)
        XCTAssertTrue(buffer.plainLines()[21].hasPrefix("│ Add folder  ~/pr "))
        XCTAssertEqual(buffer[2, 21].style, TextStyle(color: .cyan))
        XCTAssertEqual(buffer[18, 21].style, TextStyle(inverse: true))
    }

    func testTypingBackspaceAndEnterAddsThePathAndClosesTheInput() {
        let list = FakeList([])
        var editor = editor(list)
        _ = editor.handle(.character("a"))
        type("xy", into: &editor)
        _ = editor.handle(.backspace)
        type("z", into: &editor)
        XCTAssertFalse(editor.handle(.enter))
        XCTAssertEqual(list.added, ["~/xz"])
        XCTAssertNil(editor.input)
        XCTAssertNil(editor.error)
        XCTAssertEqual(editor.paths, ["~/xz"])
    }

    func testRejectedPathShowsYellowErrorAndKeepsTheInputOpen() {
        let list = FakeList(["/a"])
        list.addError = Rejected()
        var editor = editor(list)
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        XCTAssertEqual(editor.input?.text, "~/")
        XCTAssertEqual(editor.error, "that path is not allowed")
        let buffer = editor.render(width: 80, height: 24)
        XCTAssertTrue(buffer.plainLines()[20].hasPrefix("│ that path is not allowed"))
        XCTAssertEqual(buffer[2, 20].style, TextStyle(color: .yellow))
        XCTAssertTrue(buffer.plainLines()[21].hasPrefix("│ Add folder  ~/ "))
        XCTAssertEqual(list.paths, ["/a"])
    }

    func testLongErrorWrapsOverTwoRowsAboveTheInput() {
        let list = FakeList([])
        list.addError = PathListError("Protected paths cannot be empty, the filesystem root, or contain only a very short folder, pick another folder instead")
        var editor = editor(list)
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        let rows = lines(editor)
        XCTAssertTrue(rows[19].hasPrefix("│ Protected paths cannot be empty"), rows[19])
        XCTAssertTrue(rows[20].contains("instead"), rows[20])
        XCTAssertTrue(rows[21].hasPrefix("│ Add folder  ~/"), rows[21])
    }

    func testEditingClearsTheErrorAndKeepsTheInput() {
        let list = FakeList([])
        list.addError = Rejected()
        var editor = editor(list)
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        _ = editor.handle(.character("x"))
        XCTAssertNil(editor.error)
        XCTAssertEqual(editor.input?.text, "~/x")
    }

    func testEscapeInTheInputCancelsItWithoutLeaving() {
        var editor = editor(FakeList([]))
        _ = editor.handle(.character("a"))
        XCTAssertFalse(editor.handle(.escape))
        XCTAssertNil(editor.input)
        XCTAssertTrue(editor.handle(.escape))
    }

    func testListKeysTypeIntoTheInputInsteadOfActing() {
        var editor = editor(FakeList(["/a", "/b"]))
        _ = editor.handle(.character("a"))
        type("dd", into: &editor)
        XCTAssertEqual(editor.input?.text, "~/dd")
        XCTAssertEqual(editor.paths, ["/a", "/b"])
    }

    func testDRemovesTheFocusedPathWithoutAskingAndKeepsFocusInRange() {
        let list = FakeList(["/a", "/b"])
        var editor = editor(list)
        _ = editor.handle(.down)
        _ = editor.handle(.character("d"))
        XCTAssertEqual(list.removed, ["/b"])
        XCTAssertEqual(editor.paths, ["/a"])
        XCTAssertEqual(editor.focus, 0)
    }

    func testRemoveOnEmptyListDoesNothing() {
        let list = FakeList([])
        var editor = editor(list, confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        XCTAssertTrue(list.removed.isEmpty)
        XCTAssertNil(editor.confirmation)
    }

    func testRemovalPromptFocusesCancelAndShowsTheDialog() {
        var editor = editor(FakeList(["\(Safety.home)/secret"]), confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        XCTAssertEqual(editor.confirmation?.index, 0)
        let text = lines(editor).joined(separator: "\n")
        XCTAssertTrue(text.contains("Stop protecting ~/secret?"), text)
        XCTAssertTrue(text.contains("› Cancel ‹"), text)
        XCTAssertTrue(text.contains("[ Remove protection ]"), text)
        XCTAssertTrue(text.contains("Enter select"), text)
        XCTAssertTrue(text.contains("Esc back"), text)
    }

    func testRemovalPromptEnterOnCancelAndEscapeKeepThePath() {
        let list = FakeList(["/a"])
        var editor = editor(list, confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        XCTAssertFalse(editor.handle(.enter))
        XCTAssertNil(editor.confirmation)
        _ = editor.handle(.character("d"))
        XCTAssertFalse(editor.handle(.escape))
        XCTAssertNil(editor.confirmation)
        XCTAssertTrue(list.removed.isEmpty)
    }

    func testRemovalPromptNAndQCancelWithoutRemovingOrLeaving() {
        for key in [TerminalKey.character("n"), .character("N"), .character("q"), .character("Q")] {
            let list = FakeList(["/a"])
            var editor = editor(list, confirmsRemoval: true)
            _ = editor.handle(.character("d"))
            XCTAssertFalse(editor.handle(key), "\(key)")
            XCTAssertNil(editor.confirmation, "\(key)")
            XCTAssertTrue(list.removed.isEmpty, "\(key)")
        }
    }

    func testRemovalPromptRemoveButtonIsNotTriggeredByForwardDelete() {
        let list = FakeList(["/a"])
        var editor = editor(list, confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        XCTAssertFalse(editor.handle(.delete))
        XCTAssertNotNil(editor.confirmation)
        XCTAssertTrue(list.removed.isEmpty)
    }

    func testRemovalPromptEnterOnRemoveDeletesThePath() {
        let list = FakeList(["/a", "/b"])
        var editor = editor(list, confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        _ = editor.handle(.right)
        XCTAssertEqual(editor.confirmation?.index, 1)
        _ = editor.handle(.enter)
        XCTAssertEqual(list.removed, ["/a"])
        XCTAssertNil(editor.confirmation)
        XCTAssertEqual(editor.paths, ["/b"])
    }

    func testRemovalPromptSwallowsListKeys() {
        let list = FakeList(["/a", "/b"])
        var editor = editor(list, confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        _ = editor.handle(.down)
        _ = editor.handle(.character("a"))
        XCTAssertEqual(editor.focus, 0)
        XCTAssertNil(editor.input)
    }

    func testFailedRemovalShowsTheError() {
        struct Failing: Error, LocalizedError { var errorDescription: String? { "disk is read-only" } }
        var config = FakeList(["/a"]).config()
        config.remove = { _ in throw Failing() }
        var editor = PathListEditor(config)
        _ = editor.handle(.character("d"))
        XCTAssertEqual(editor.error, "disk is read-only")
        XCTAssertEqual(editor.paths, ["/a"])
        let rows = lines(editor)
        XCTAssertTrue(rows[20].hasPrefix("├"), rows[20])
        XCTAssertTrue(rows[21].hasPrefix("│ disk is read-only"), rows[21])
    }

    func testBrowseModeWithoutAnErrorPutsTheHintsRightBelowTheDivider() {
        let rows = lines(editor(FakeList(["/a"])))
        XCTAssertTrue(rows[21].hasPrefix("├"), rows[21])
        XCTAssertTrue(rows[22].contains("↑↓ move"), rows[22])
    }

    func testLoadFailureShowsAnEmptyListWithTheError() {
        let list = FakeList([])
        list.loadError = Rejected()
        let editor = editor(list)
        XCTAssertEqual(editor.paths, [])
        XCTAssertEqual(editor.loadError, "that path is not allowed")
        XCTAssertNil(editor.error)
    }

    func testLoadFailureStaysInPlaceOfTheEmptyStateAfterAKey() {
        let list = FakeList([])
        list.loadError = Rejected()
        var editor = editor(list)
        _ = editor.handle(.down)
        let buffer = editor.render(width: 80, height: 24)
        let rows = buffer.plainLines()
        XCTAssertTrue(rows[1].hasPrefix("│ that path is not allowed"), rows[1])
        XCTAssertEqual(buffer[2, 1].style, TextStyle(color: .red))
        XCTAssertFalse(rows.joined().contains("Nothing here yet"))
    }

    func testLongLoadFailureWrapsInsideTheList() {
        let list = FakeList([])
        list.loadError = PathListError("Configuration file is not a valid PureMac settings file: /Users/someone/.config/puremac/config.json")
        let rows = lines(editor(list))
        XCTAssertTrue(rows[1].hasPrefix("│ Configuration file is not a valid PureMac settings file: "), rows[1])
        XCTAssertTrue(rows[2].hasPrefix("│ /Users/someone/.config/puremac/config.json "), rows[2])
    }

    func testLoadFailureGoesAwayOnceALoadSucceeds() {
        let list = FakeList([])
        list.loadError = Rejected()
        var editor = editor(list)
        list.loadError = nil
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        XCTAssertNil(editor.loadError)
        XCTAssertEqual(editor.paths, ["~/"])
    }

    func testReloadFailureAfterAnAddClearsTheStaleList() {
        let list = FakeList(["/a"])
        var editor = editor(list)
        list.loadError = Rejected()
        _ = editor.handle(.character("a"))
        _ = editor.handle(.enter)
        XCTAssertNil(editor.input)
        XCTAssertEqual(editor.paths, [])
        XCTAssertEqual(editor.loadError, "that path is not allowed")
    }

    func testRowsAreShortenedWithFocusPointerAndMissingNote() {
        let missing = "\(Safety.home)/puremac-missing-\(UUID().uuidString)"
        let shown = Render.shorten(missing)
        let editor = editor(FakeList([missing, existing]))
        let buffer = editor.render(width: 80, height: 24)
        let rows = buffer.plainLines()
        XCTAssertTrue(rows[1].hasPrefix("│ › \(shown) not found "), rows[1])
        XCTAssertTrue(rows[1].hasPrefix("│ › ~/puremac-missing-"), rows[1])
        XCTAssertTrue(rows[1].hasSuffix(" │"), rows[1])
        XCTAssertTrue(rows[2].hasPrefix("│   \(existing)"), rows[2])
        XCTAssertFalse(rows[2].contains("not found"))
        XCTAssertEqual(buffer[2, 1].style, TextStyle(color: .cyan, inverse: true))
        XCTAssertEqual(buffer[4, 1].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[3 + shown.count, 1].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[4 + shown.count, 1].style, TextStyle(dim: true, inverse: true))
        XCTAssertEqual(buffer[13 + shown.count, 1].style, TextStyle(dim: true, inverse: true))
        XCTAssertEqual(buffer[14 + shown.count, 1].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[77, 1].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[4, 2].style, .plain)
    }

    func testTitleHintsAndEmptyState() {
        let rows = lines(editor(FakeList([])))
        XCTAssertTrue(rows[0].contains("Project folders"), rows[0])
        XCTAssertTrue(rows[1].hasPrefix("│ Nothing here yet. Press A to add one."), rows[1])
        XCTAssertTrue(rows[22].contains("↑↓ move  A add  D remove  Esc back"), rows[22])
    }

    func testInputModeShowsItsOwnHints() {
        var editor = editor(FakeList([]))
        _ = editor.handle(.character("a"))
        let row = lines(editor)[22]
        XCTAssertTrue(row.contains("Enter add  Esc cancel"), row)
        XCTAssertFalse(row.contains("remove"), row)
    }

    func testScrollbarAppearsOnlyWhenTheListDoesNotFit() {
        let many = FakeList((0..<40).map { "/p\($0)" })
        XCTAssertTrue(lines(editor(many), height: 12)[1].hasSuffix("┃"))
        XCTAssertFalse(lines(editor(FakeList(["/a"])), height: 12)[1].hasSuffix("┃"))
    }

    func testFocusedRowScrollsIntoView() {
        var editor = editor(FakeList((0..<40).map { "/p\($0)" }))
        for _ in 0..<30 { _ = editor.handle(.down) }
        let text = lines(editor, height: 12).joined(separator: "\n")
        XCTAssertTrue(text.contains("› /p30"), text)
    }

    func testTooSmallTerminalShowsTheTooSmallScreen() {
        let text = lines(editor(FakeList(["/a"])), width: 39, height: 24).joined(separator: "\n")
        XCTAssertTrue(text.contains("Terminal too small"), text)
        XCTAssertTrue(text.contains("Esc back"), text)
        XCTAssertFalse(text.contains("/a"), text)
    }

    func testTooSmallListAcceptsOnlyEscape() {
        let editor = editor(FakeList(["/a"]))
        XCTAssertTrue(editor.acceptsKey(.escape, tooSmall: true))
        for key in [TerminalKey.character("d"), .character("a"), .enter, .down, .character("q")] {
            XCTAssertFalse(editor.acceptsKey(key, tooSmall: true), "\(key)")
            XCTAssertTrue(editor.acceptsKey(key, tooSmall: false), "\(key)")
        }
    }

    func testTooSmallInputAcceptsOnlyEscape() {
        var editor = editor(FakeList([]))
        _ = editor.handle(.character("a"))
        XCTAssertTrue(editor.acceptsKey(.escape, tooSmall: true))
        XCTAssertFalse(editor.acceptsKey(.character("x"), tooSmall: true))
        XCTAssertFalse(editor.acceptsKey(.enter, tooSmall: true))
    }

    func testTooSmallDialogAcceptsEscapeAndEnterOnCancelOnly() {
        var editor = editor(FakeList(["/a"]), confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        XCTAssertTrue(editor.acceptsKey(.escape, tooSmall: true))
        XCTAssertTrue(editor.acceptsKey(.enter, tooSmall: true))
        XCTAssertFalse(editor.acceptsKey(.right, tooSmall: true))
        for key in ["n", "N", "q", "Q"] { XCTAssertTrue(editor.acceptsKey(.character(Character(key)), tooSmall: true), key) }
        XCTAssertFalse(editor.acceptsKey(.character("y"), tooSmall: true))
        _ = editor.handle(.right)
        XCTAssertFalse(editor.acceptsKey(.enter, tooSmall: true))
        XCTAssertTrue(editor.acceptsKey(.enter, tooSmall: false))
    }

    func testForwardDeleteDoesNotLeaveTheList() {
        var editor = editor(FakeList(["/a"]))
        XCTAssertFalse(editor.handle(.delete))
    }

    func testLeavesOnQLeftAndBackspaceToo() {
        for key in [TerminalKey.character("q"), .character("Q"), .left, .backspace] {
            var editor = editor(FakeList(["/a"]))
            XCTAssertTrue(editor.handle(key), "\(key)")
        }
    }

    func testQTypesIntoTheInputInsteadOfLeaving() {
        var editor = editor(FakeList([]))
        _ = editor.handle(.character("a"))
        XCTAssertFalse(editor.handle(.character("q")))
        XCTAssertEqual(editor.input?.text, "~/q")
    }

    func testRemovalDialogKeepsTheEndOfALongPathAndTheQuestionMark() {
        let long = "/Users/someone/projects/client-work/deeply/nested/folder/final-name"
        var editor = editor(FakeList([long]), confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        for width in [40, 80] {
            let text = lines(editor, width: width).joined(separator: "\n")
            XCTAssertTrue(text.contains("Stop protecting "), "\(width)\n\(text)")
            XCTAssertTrue(text.contains("…"), "\(width)\n\(text)")
            XCTAssertTrue(text.contains("name?"), "\(width)\n\(text)")
        }
    }

    func testRemovalDialogShowsTheWholeDestructiveButtonAt40Columns() {
        var editor = editor(FakeList(["/Users/someone/projects/final-name"]), confirmsRemoval: true)
        _ = editor.handle(.character("d"))
        let text = lines(editor, width: 40, height: 12).joined(separator: "\n")
        XCTAssertTrue(text.contains("› Cancel ‹"), text)
        XCTAssertTrue(text.contains("[ Remove protection ]"), text)
    }
}

final class ProjectFoldersTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("work", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-folders-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddSavesTheStandardizedFolderThroughTheProjectsFile() throws {
        try withConfigHome { _ in
            let config = PathListConfig.projectFolders
            try config.add(folder.path + "/")
            XCTAssertEqual(try ProjectFoldersStore(fileURL: AppPaths.projectsFile).roots, Purger.defaultRoots + [folder.path])
            XCTAssertEqual(try config.load(), Purger.defaultRoots + [folder.path])
        }
    }

    func testAddRejectsADuplicate() throws {
        try withConfigHome { _ in
            let config = PathListConfig.projectFolders
            try config.add(folder.path)
            XCTAssertThrowsError(try config.add(folder.path + "/")) { error in
                XCTAssertEqual(error.localizedDescription, "Already in the list: \(Render.shorten(folder.path))")
            }
            XCTAssertEqual(try config.load().filter { $0 == folder.path }.count, 1)
        }
    }

    func testAddRejectsWhatSafetyRejectsWithItsReason() throws {
        try withConfigHome { _ in
            let config = PathListConfig.projectFolders
            for path in ["/", Safety.home, "/Library"] {
                let reason = try XCTUnwrap(Safety.isValidScanRoot(path).reason)
                XCTAssertThrowsError(try config.add(path), path) { error in
                    XCTAssertEqual(error.localizedDescription, reason)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.configFile.path))
        }
    }

    func testAddRejectsMissingFoldersAndFiles() throws {
        try withConfigHome { _ in
            let file = root.appendingPathComponent("file.txt")
            try Data().write(to: file)
            for path in [root.appendingPathComponent("nope").path, file.path] {
                let reason = try XCTUnwrap(Safety.isValidScanRoot(path).reason)
                XCTAssertThrowsError(try PathListConfig.projectFolders.add(path), path) { error in
                    XCTAssertEqual(error.localizedDescription, reason)
                }
            }
        }
    }

    func testAddRejectsEmptyInput() throws {
        try withConfigHome { _ in
            XCTAssertThrowsError(try PathListConfig.projectFolders.add("  ")) { error in
                XCTAssertEqual(error.localizedDescription, "Enter a folder path")
            }
        }
    }

    func testAddRejectsTheHomeFolder() throws {
        try withConfigHome { _ in
            XCTAssertThrowsError(try PathListConfig.projectFolders.add("~/")) { error in
                XCTAssertEqual(error.localizedDescription, Safety.isValidScanRoot("~/").reason)
            }
        }
    }

    func testRemoveSavesTheShorterList() throws {
        try withConfigHome { _ in
            let config = PathListConfig.projectFolders
            try config.add(folder.path)
            try config.remove(Purger.defaultRoots[0])
            XCTAssertEqual(try config.load(), Array(Purger.defaultRoots.dropFirst()) + [folder.path])
        }
    }

    func testProjectFoldersHaveNoRemovalPrompt() {
        XCTAssertNil(PathListConfig.projectFolders.removalPrompt)
    }
}

final class ProtectedPathsListTests: XCTestCase {
    func testAddAndRemoveGoThroughTheIgnoreFileAndLoadIsSorted() throws {
        try withConfigHome { _ in
            let config = PathListConfig.protectedPaths
            try config.add("/tmp/puremac-b")
            try config.add("/tmp/puremac-a")
            XCTAssertEqual(try config.load(), ["/tmp/puremac-a", "/tmp/puremac-b"])
            try config.remove("/tmp/puremac-a")
            XCTAssertEqual(try config.load(), ["/tmp/puremac-b"])
            XCTAssertEqual(try IgnoreStore(fileURL: AppPaths.ignoreFile).roots, ["/tmp/puremac-b"])
        }
    }

    func testAddKeepsTheStoreValidationError() throws {
        try withConfigHome { _ in
            XCTAssertThrowsError(try PathListConfig.protectedPaths.add("/")) { error in
                XCTAssertEqual(error.localizedDescription, StoreError.invalidIgnorePath.localizedDescription)
            }
        }
    }

    func testAddingAPathThatIsAlreadyListedThrowsAndKeepsOneCopy() throws {
        try withConfigHome { _ in
            let config = PathListConfig.protectedPaths
            try config.add("/tmp/puremac-a")
            XCTAssertThrowsError(try config.add("/tmp/puremac-a/")) { error in
                XCTAssertEqual(error.localizedDescription, "Already in the list: /tmp/puremac-a")
            }
            XCTAssertEqual(try config.load(), ["/tmp/puremac-a"])
        }
    }

    func testRemovalAsksWithTheShortenedPathAndTheDestructiveLabel() throws {
        let prompt = try XCTUnwrap(PathListConfig.protectedPaths.removalPrompt)
        XCTAssertEqual(prompt.title("~/secret"), "Stop protecting ~/secret?")
        XCTAssertEqual(prompt.button, "Remove protection")
    }
}
