import Foundation
import TerminalUI

enum PreferencesAction: Equatable {
    case back, openProjectFolders, openProtectedPaths
}

struct PreferencesScreen {
    enum Row: Int, CaseIterable {
        case age, projectFolders, protectedPaths
    }

    private(set) var days = ConfigStore.defaultDays
    private(set) var folderCount = Purger.defaultRoots.count
    private(set) var pathCount = 0
    private(set) var focus = Row.age
    private var loadError: String?
    private var configUnreadable = false
    private var saveError: String?
    private let setupError: String?

    static let presets = [1, 3, 7, 14, 30, 60, 90, 180, 365]
    private static let title = "Preferences"
    private static let hints = KeyHints([
        KeyHint("↑↓", "move"), KeyHint("←→", "change"), KeyHint("Enter", "open"), KeyHint("Esc", "back"),
    ])
    private static let ageLabel = "Preselect artifacts older than"
    private static let foldersLabel = "Project folders"
    private static let pathsLabel = "Protected paths"
    private static var widestValue: Int { Term.displayWidth(ageValue(presets.max() ?? 0)) }
    private static let maxErrorRows = 3

    init(setupError: Error? = nil) {
        self.setupError = setupError.map { "Could not create settings files: \($0.localizedDescription)" }
        reload()
    }

    private static func ageValue(_ days: Int) -> String {
        "‹ \(Render.counted(days, "day")) ›"
    }

    mutating func reload() {
        loadError = nil
        configUnreadable = false
        do {
            let store = try ConfigStore(fileURL: AppPaths.configFile)
            days = store.olderThanDays
        } catch {
            days = ConfigStore.defaultDays
            loadError = error.localizedDescription
            configUnreadable = true
        }
        do {
            folderCount = try ProjectFoldersStore(fileURL: AppPaths.projectsFile).roots.count
        } catch {
            folderCount = Purger.defaultRoots.count
            loadError = loadError ?? error.localizedDescription
        }
        do {
            pathCount = try IgnoreStore(fileURL: AppPaths.ignoreFile).roots.count
        } catch {
            pathCount = 0
            loadError = loadError ?? error.localizedDescription
        }
    }

    mutating func handle(_ key: TerminalKey) -> PreferencesAction? {
        saveError = nil
        switch key {
        case .up: move(-1)
        case .down: move(1)
        case .left: if focus == .age { changeDays(to: Self.presets.last { $0 < days }) }
        case .right: if focus == .age { changeDays(to: Self.presets.first { $0 > days }) }
        case .enter:
            switch focus {
            case .age: break
            case .projectFolders: return .openProjectFolders
            case .protectedPaths: return .openProtectedPaths
            }
        case .escape: return .back
        case .character(let character): return character.lowercased() == "q" ? .back : nil
        default: break
        }
        return nil
    }

    func acceptsKey(_ key: TerminalKey, tooSmall: Bool) -> Bool {
        !tooSmall || key == .escape
    }

    private mutating func move(_ delta: Int) {
        let index = min(Row.allCases.count - 1, max(0, focus.rawValue + delta))
        focus = Row(rawValue: index) ?? focus
    }

    private mutating func changeDays(to target: Int?) {
        guard let target, !configUnreadable else { return }
        do {
            var store = try ConfigStore(fileURL: AppPaths.configFile)
            try store.set(ConfigStore.daysKey, String(target))
            days = target
        } catch {
            saveError = error.localizedDescription
        }
    }

    func render(width: Int, height: Int) -> Buffer {
        guard TooSmallScreen.fits(width: width, height: height) else {
            return TooSmallScreen.render(title: Self.title, exitHint: "Esc back", width: width, height: height)
        }
        var buffer = Buffer(width: width, height: height)
        let window = Window(title: Self.title)
        let content = window.render(in: buffer.area, buffer: &buffer)
        let lines = listLines(width: content.width)
        let footerRows = Self.hints.rows(width: content.width).count
        let areas = content.splitRows([.fill, .length(1), .length(1), .length(footerRows)])
        let (main, saved, divider, footer) = (areas[0], areas[1], areas[2], areas[3])
        let parts = main.splitRows([.length(lines.count), .fill])
        let (list, status) = (parts[0], parts[1])

        for (offset, line) in lines.prefix(list.height).enumerated() {
            buffer.write(line, x: list.x, y: list.y + offset, maxWidth: list.width)
        }
        let errors = errorRows(width: content.width)
        for (offset, row) in errors.prefix(status.height).enumerated() {
            buffer.write(row, x: status.x, y: status.y + offset, maxWidth: status.width)
        }
        if let first = errors.first, status.height == 0 {
            buffer.write(first, x: saved.x, y: saved.y, maxWidth: saved.width)
        } else {
            let location = Term.truncate("Saved in " + Render.shorten(AppPaths.configDir.path), to: saved.width, middle: true)
            buffer.write(location, x: saved.x, y: saved.y, style: TextStyle(dim: true))
        }
        window.renderDivider(atRow: divider.y, in: buffer.area, buffer: &buffer)
        Self.hints.render(in: footer, buffer: &buffer)
        return buffer
    }

    private func errorRows(width: Int) -> [[Span]] {
        let messages = [
            setupError.map { Span($0, TextStyle(color: .yellow)) },
            saveError.map { Span($0, TextStyle(color: .yellow)) },
            loadError.map { Span($0, TextStyle(color: .red)) },
        ].compactMap { $0 }
        return Array(messages.flatMap { Term.wordWrap([$0], width: width) }.prefix(Self.maxErrorRows))
    }

    private func listLines(width: Int) -> [[Span]] {
        let rows: [(row: Row, label: String, value: String)] = [
            (.age, Self.ageLabel, Self.ageValue(days)),
            (.projectFolders, Self.foldersLabel, "\(Render.counted(folderCount, "folder")) ›"),
            (.protectedPaths, Self.pathsLabel, "\(Render.counted(pathCount, "path")) ›"),
        ]
        let valueWidth = rows.map { Term.displayWidth($0.value) }.reduce(Self.widestValue, max)
        let widestLabel = rows.map { Term.displayWidth($0.label) }.max() ?? 1
        let labelWidth = max(1, min(widestLabel, width - 2 - 2 - valueWidth))
        func line(_ item: (row: Row, label: String, value: String)) -> [Span] {
            let text = " " + Term.pad(Term.truncate(item.label, to: labelWidth), to: labelWidth) + "  " + item.value
            return [
                FocusPointer.span(focused: focus == item.row),
                Span(Term.pad(text, to: width - 1), TextStyle(inverse: focus == item.row)),
            ]
        }
        return [
            [Span("Project cleanup", TextStyle(bold: true))],
            line(rows[0]),
            line(rows[1]),
            [],
            [Span("Protection", TextStyle(bold: true))],
            line(rows[2]),
        ]
    }

    static func run(setupError: Error?, in session: TerminalSession) {
        var screen = PreferencesScreen(setupError: setupError)
        while true {
            session.draw(screen.render(width: session.width, height: session.height))
            let key = session.readKey()
            let tooSmall = !TooSmallScreen.fits(width: session.width, height: session.height)
            guard screen.acceptsKey(key, tooSmall: tooSmall) else { continue }
            switch screen.handle(key) {
            case .back: return
            case .openProjectFolders:
                PathListEditor.run(.projectFolders, in: session)
                screen.reload()
            case .openProtectedPaths:
                PathListEditor.run(.protectedPaths, in: session)
                screen.reload()
            case nil: break
            }
        }
    }
}
