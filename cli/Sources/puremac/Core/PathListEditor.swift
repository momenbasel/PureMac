import Foundation
import TerminalUI

struct PathListError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    static func duplicate(_ path: String) -> PathListError {
        PathListError("Already in the list: \(Render.shorten(path))")
    }

    var errorDescription: String? { message }
}

struct RemovalPrompt {
    var title: (String) -> String
    var button: String
}

struct PathListConfig {
    var title: String
    var emptyText: String
    var load: () throws -> [String]
    var add: (String) throws -> Void
    var remove: (String) throws -> Void
    var removalPrompt: RemovalPrompt?
    var inputLabel = "Add folder"
}

extension PathListConfig {
    private static func standardized(_ path: String) -> String {
        (Safety.absolutePath(path) as NSString).standardizingPath
    }

    static var projectFolders: PathListConfig {
        PathListConfig(
            title: "Project folders",
            emptyText: "No project folders. Press A to add one.",
            load: { try ProjectFoldersStore(fileURL: AppPaths.projectsFile).roots },
            add: { input in
                let typed = input.trimmingCharacters(in: .whitespaces)
                guard !typed.isEmpty else { throw PathListError("Enter a folder path") }
                let verdict = Safety.isValidScanRoot(typed)
                guard verdict.ok else { throw PathListError(verdict.reason ?? "Not a valid project folder") }
                var store = try ProjectFoldersStore(fileURL: AppPaths.projectsFile)
                let root = standardized(typed)
                guard try store.add(root) else { throw PathListError.duplicate(root) }
            },
            remove: { path in
                var store = try ProjectFoldersStore(fileURL: AppPaths.projectsFile)
                _ = try store.remove(path)
            },
            removalPrompt: nil
        )
    }

    static var protectedPaths: PathListConfig {
        PathListConfig(
            title: "Protected paths",
            emptyText: "No protected paths. Press A to add one.",
            load: { try IgnoreStore(fileURL: AppPaths.ignoreFile).roots.sorted() },
            add: { path in
                var store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
                guard try store.add(path) else {
                    throw PathListError.duplicate(standardized(path))
                }
            },
            remove: { path in
                var store = try IgnoreStore(fileURL: AppPaths.ignoreFile)
                _ = try store.remove(path)
            },
            removalPrompt: RemovalPrompt(
                title: { "Stop protecting \($0)?" },
                button: "Remove protection"
            ),
            inputLabel: "Add path"
        )
    }
}

struct PathListEditor {
    private let config: PathListConfig
    private(set) var paths: [String] = []
    private(set) var focus = 0
    private(set) var input: TextInput?
    private(set) var confirmation: ButtonFocus?
    private(set) var error: String?
    private(set) var loadError: String?

    private static let browseHints = KeyHints([
        KeyHint("↑↓", "move"), KeyHint("A", "add"), KeyHint("D", "remove"), KeyHint("Esc", "back"),
    ])
    private static let inputHints = KeyHints([KeyHint("Enter", "add"), KeyHint("Esc", "cancel")])
    private static let maxErrorRows = 2
    private static let buttonCount = 2
    private static let cancelIndex = 0
    private static let removeIndex = buttonCount - 1
    private static let notFound = " not found"

    init(_ config: PathListConfig) {
        self.config = config
        reload()
    }

    mutating func handle(_ key: TerminalKey) -> Bool {
        error = nil
        if confirmation != nil {
            handleConfirmation(key)
        } else if input != nil {
            handleInput(key)
        } else {
            return handleList(key)
        }
        return false
    }

    func acceptsKey(_ key: TerminalKey, tooSmall: Bool) -> Bool {
        guard tooSmall else { return true }
        if let confirmation {
            if case .character(let character) = key, ["n", "q"].contains(character.lowercased()) { return true }
            return key == .escape || (key == .enter && confirmation.index == Self.cancelIndex)
        }
        return key == .escape
    }

    private mutating func handleList(_ key: TerminalKey) -> Bool {
        switch key {
        case .up: move(-1)
        case .down: move(1)
        case .escape, .left, .backspace: return true
        case .character(let character):
            switch character.lowercased() {
            case "q": return true
            case "a": input = TextInput("~/")
            case "d": beginRemoval()
            default: break
            }
        default: break
        }
        return false
    }

    private mutating func handleInput(_ key: TerminalKey) {
        switch key {
        case .enter:
            guard let text = input?.text else { return }
            let add = config.add
            let before = Set(paths)
            guard perform({ try add(text) }) else { return }
            input = nil
            if let added = paths.firstIndex(where: { !before.contains($0) }) { focus = added }
        case .escape: input = nil
        default: input?.handle(key)
        }
    }

    private mutating func handleConfirmation(_ key: TerminalKey) {
        guard var buttons = confirmation else { return }
        if buttons.navigate(key) {
            confirmation = buttons
            return
        }
        switch key {
        case .enter:
            confirmation = nil
            if buttons.index == Self.removeIndex { removeFocused() }
        case .escape: confirmation = nil
        case .character(let character) where ["n", "q"].contains(character.lowercased()): confirmation = nil
        default: break
        }
    }

    private mutating func move(_ delta: Int) {
        focus = min(max(0, paths.count - 1), max(0, focus + delta))
    }

    private mutating func beginRemoval() {
        guard paths.indices.contains(focus) else { return }
        if config.removalPrompt != nil {
            confirmation = ButtonFocus(count: Self.buttonCount, index: Self.cancelIndex)
        } else {
            removeFocused()
        }
    }

    private mutating func removeFocused() {
        let path = paths[focus]
        let remove = config.remove
        perform { try remove(path) }
    }

    @discardableResult
    private mutating func perform(_ change: () throws -> Void) -> Bool {
        do {
            try change()
        } catch {
            self.error = error.localizedDescription
            return false
        }
        reload()
        return true
    }

    private mutating func reload() {
        do {
            paths = try config.load()
            loadError = nil
        } catch {
            paths = []
            loadError = error.localizedDescription
        }
        move(0)
    }

    func render(width: Int, height: Int) -> Buffer {
        guard TooSmallScreen.fits(width: width, height: height) else {
            return TooSmallScreen.render(title: config.title, exitHint: "Esc back", width: width, height: height)
        }
        var buffer = Buffer(width: width, height: height)
        let window = Window(title: config.title)
        let content = window.render(in: buffer.area, buffer: &buffer)
        let hints = input == nil ? Self.browseHints : Self.inputHints
        let errorRows = errorRows(width: content.width)
        let areas = content.splitRows([
            .fill,
            .length(1),
            .length(errorRows.count),
            .length(input == nil ? 0 : 1),
            .length(hints.rows(width: content.width).count),
        ])
        let (list, divider, status, field, footer) = (areas[0], areas[1], areas[2], areas[3], areas[4])

        window.renderDivider(atRow: divider.y, in: buffer.area, buffer: &buffer)
        hints.render(in: footer, buffer: &buffer)
        for (offset, row) in errorRows.enumerated() {
            buffer.write(row, x: status.x, y: status.y + offset, maxWidth: status.width)
        }
        if let input {
            buffer.write(input.fieldSpans(label: config.inputLabel + "  ", width: field.width), x: field.x, y: field.y, maxWidth: field.width)
        }
        renderList(in: list, buffer: &buffer)
        guard let confirmation, let prompt = config.removalPrompt, paths.indices.contains(focus) else { return buffer }
        let dialog = Dialog(
            title: Self.removalTitle(prompt, path: paths[focus], area: buffer.area),
            titleStyle: StatusScreen.warningTitle,
            borderStyle: StatusScreen.warningBorder,
            buttons: [DialogButton("Cancel"), DialogButton(prompt.button, role: .destructive)],
            focusedButton: confirmation.index,
            hints: StatusScreen.choiceHints
        )
        return StatusScreen.overlay(dialog, on: buffer)
    }

    private static func removalTitle(_ prompt: RemovalPrompt, path: String, area: Rect) -> String {
        let room = Dialog.maxTitleWidth(in: area) - Term.displayWidth(prompt.title(""))
        return prompt.title(Term.truncate(Render.shorten(path), to: max(1, room), middle: true))
    }

    private func errorRows(width: Int) -> [[Span]] {
        guard let error else { return [] }
        return Array(Term.wordWrap([Span(error, TextStyle(color: .yellow))], width: width).prefix(Self.maxErrorRows))
    }

    private func renderList(in rect: Rect, buffer: inout Buffer) {
        guard !paths.isEmpty else {
            let message = loadError.map { Span($0, TextStyle(color: .red)) } ?? Span(config.emptyText, TextStyle(dim: true))
            for (offset, row) in Term.wordWrap([message], width: rect.width).prefix(rect.height).enumerated() {
                buffer.write(row, x: rect.x, y: rect.y + offset, maxWidth: rect.width)
            }
            return
        }
        let start = Scrollbar.centeredOffset(total: paths.count, visible: rect.height, focus: focus)
        for (index, path) in paths.enumerated().dropFirst(start).prefix(rect.height) {
            renderRow(path, focused: index == focus, in: Rect(x: rect.x, y: rect.y + index - start, width: rect.width, height: 1), buffer: &buffer)
        }
        Scrollbar(total: paths.count, visible: rect.height, offset: start)
            .render(column: buffer.width - 1, rows: rect.y..<(rect.y + rect.height), buffer: &buffer)
    }

    private func renderRow(_ path: String, focused: Bool, in rect: Rect, buffer: inout Buffer) {
        let rowStyle = TextStyle(inverse: focused)
        let note = FileManager.default.fileExists(atPath: path) ? "" : Self.notFound
        let noteWidth = Term.displayWidth(note)
        let shown = Term.truncate(Render.shorten(path), to: max(1, rect.width - 2 - noteWidth), middle: true)
        let rest = max(0, rect.width - 2 - Term.displayWidth(shown) - noteWidth)
        buffer.write(
            [
                FocusPointer.span(focused: focused),
                Span(" " + shown, rowStyle),
                Span(note, TextStyle(dim: true, inverse: focused)),
                Span(String(repeating: " ", count: rest), rowStyle),
            ],
            x: rect.x,
            y: rect.y,
            maxWidth: rect.width
        )
    }

    static func run(_ config: PathListConfig, in session: TerminalSession) {
        var editor = PathListEditor(config)
        while true {
            session.draw(editor.render(width: session.width, height: session.height))
            let key = session.readKey()
            let tooSmall = !TooSmallScreen.fits(width: session.width, height: session.height)
            guard editor.acceptsKey(key, tooSmall: tooSmall) else { continue }
            if editor.handle(key) { return }
        }
    }
}
