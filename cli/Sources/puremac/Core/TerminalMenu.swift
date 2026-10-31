import Foundation
import TerminalUI

struct TerminalMenuModel {
    let optionCount: Int
    private(set) var selection: Int

    init(optionCount: Int, selection: Int = 0) {
        self.optionCount = optionCount
        self.selection = min(max(0, optionCount - 1), max(0, selection))
    }

    mutating func move(_ delta: Int) {
        guard optionCount > 0 else { return }
        selection = min(optionCount - 1, max(0, selection + delta))
    }

    mutating func moveToStart() {
        selection = 0
    }

    mutating func moveToEnd() {
        selection = max(0, optionCount - 1)
    }

    mutating func select(number: Int) -> Int? {
        let index = number - 1
        guard (1...9).contains(number), index < optionCount else { return nil }
        selection = index
        return selection
    }
}

enum TerminalMenu {
    static func choose(
        title: String,
        subtitle: String,
        options: [(title: String, detail: String)],
        initialSelection: Int = 0
    ) throws -> Int? {
        guard !options.isEmpty else { return nil }
        let session = try TerminalSession()
        defer { session.close() }

        var model = TerminalMenuModel(optionCount: options.count, selection: initialSelection)
        while true {
            session.draw(
                render(
                    title: title,
                    subtitle: subtitle,
                    options: options,
                    selection: model.selection,
                    width: session.width,
                    height: session.height
                )
            )

            switch session.readKey() {
            case .up:
                model.move(-1)
            case .down:
                model.move(1)
            case .pageUp:
                model.move(-max(1, session.height / 2))
            case .pageDown:
                model.move(max(1, session.height / 2))
            case .home:
                model.moveToStart()
            case .end:
                model.moveToEnd()
            case .enter:
                return model.selection
            case .escape:
                return nil
            case .character(let character):
                if String(character).lowercased() == "q" {
                    return nil
                }
                if let number = character.wholeNumberValue,
                   let selection = model.select(number: number) {
                    return selection
                }
            default:
                break
            }
        }
    }

    static func render(
        title: String,
        subtitle: String,
        options: [(title: String, detail: String)],
        selection: Int,
        width: Int,
        height: Int
    ) -> Buffer {
        guard TooSmallScreen.fits(width: width, height: height) else {
            return TooSmallScreen.render(title: "PureMac", exitHint: "Esc/q cancel", width: width, height: height)
        }
        var buffer = Buffer(width: width, height: height)
        let window = Window(title: title)
        let content = window.render(in: buffer.area, buffer: &buffer)
        let hints = KeyHints([
            KeyHint("↑↓", "move"),
            KeyHint("PgUp/PgDn", "page"),
            KeyHint("1-9", "open"),
            KeyHint("Enter", "open"),
            KeyHint("Esc/q", "cancel")
        ])
        let areas = content.splitRows([.length(2), .fill, .length(1), .length(hints.rows(width: content.width).count)])
        let (header, list, divider, footer) = (areas[0], areas[1], areas[2], areas[3])

        buffer.write(Term.truncate(subtitle, to: header.width), x: header.x, y: header.y, style: TextStyle(dim: true))
        window.renderDivider(atRow: divider.y, in: buffer.area, buffer: &buffer)
        hints.render(in: footer, buffer: &buffer)

        let safeSelection = min(max(0, selection), max(0, options.count - 1))
        let rowHeight = 2
        let visibleCount = max(1, list.height / rowHeight)
        let start = Scrollbar.centeredOffset(total: options.count, visible: visibleCount, focus: safeSelection)
        for (index, option) in options.enumerated().dropFirst(start).prefix(visibleCount) {
            let rect = Rect(x: list.x, y: list.y + (index - start) * rowHeight, width: list.width, height: rowHeight)
            renderOption(option, number: index + 1, focused: index == safeSelection, in: rect, buffer: &buffer)
        }
        Scrollbar(total: options.count, visible: visibleCount, offset: start)
            .render(column: width - 1, rows: list.y..<(list.y + visibleCount * rowHeight), buffer: &buffer)
        return buffer
    }

    private static func renderOption(
        _ option: (title: String, detail: String),
        number: Int,
        focused: Bool,
        in rect: Rect,
        buffer: inout Buffer
    ) {
        let indent = 6
        let textWidth = max(1, rect.width - indent)
        let rowStyle = TextStyle(inverse: focused)
        let numberText = "\(number)."
        buffer.write(
            [
                FocusPointer.span(focused: focused),
                Span(" ", rowStyle),
                Span(Term.pad(numberText, to: 4), focused ? rowStyle : TextStyle(color: .cyan)),
                Span(Term.pad(Term.truncate(option.title, to: textWidth), to: textWidth), rowStyle)
            ],
            x: rect.x,
            y: rect.y,
            maxWidth: rect.width
        )
        buffer.write(
            Term.truncate(option.detail, to: textWidth),
            x: rect.x + indent,
            y: rect.y + 1,
            style: TextStyle(dim: !focused),
            maxWidth: textWidth
        )
    }
}
