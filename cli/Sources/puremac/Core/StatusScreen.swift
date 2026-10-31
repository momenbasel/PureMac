import TerminalUI

struct StatusRow {
    let text: String
    let style: TextStyle
    let truncatesInMiddle: Bool

    init(_ text: String, style: TextStyle = .plain, truncatesInMiddle: Bool = false) {
        self.text = text
        self.style = style
        self.truncatesInMiddle = truncatesInMiddle
    }
}

enum StatusScreen {
    static let warningTitle = TextStyle(color: .yellow, bold: true)
    static let cancellingText = "Cancelling…"
    static let scanHint = KeyHint("Esc/q", "cancel")
    static let warningBorder = TextStyle(color: .yellow)
    static let choiceHints = KeyHints([KeyHint("Enter", "select"), KeyHint("Esc", "back")])

    static func render(title: String, rows: [StatusRow], hint: KeyHint, width: Int, height: Int) -> Buffer {
        let hints = KeyHints([hint])
        guard TooSmallScreen.fits(width: width, height: height) else {
            return TooSmallScreen.render(title: title, exitHint: "\(hint.key) \(hint.action)", width: width, height: height)
        }
        var buffer = Buffer(width: width, height: height)
        let window = Window(title: title)
        let content = window.render(in: buffer.area, buffer: &buffer)
        let areas = content.splitRows([.length(rows.count), .fill, .length(1), .length(hints.rows(width: content.width).count)])
        let (header, divider, footer) = (areas[0], areas[2], areas[3])

        for (offset, row) in rows.enumerated() {
            buffer.write(
                Term.truncate(row.text, to: header.width, middle: row.truncatesInMiddle),
                x: header.x, y: header.y + offset, style: row.style
            )
        }
        window.renderDivider(atRow: divider.y, in: buffer.area, buffer: &buffer)
        hints.render(in: footer, buffer: &buffer)
        return buffer
    }

    static func overlay(_ dialog: Dialog, on background: Buffer, tooSmallExitHint: String? = nil) -> Buffer {
        guard TooSmallScreen.fits(width: background.width, height: background.height) else {
            guard let tooSmallExitHint else { return background }
            return TooSmallScreen.render(
                title: "PureMac", exitHint: tooSmallExitHint, width: background.width, height: background.height
            )
        }
        var buffer = background
        buffer.fade()
        dialog.render(in: buffer.area, buffer: &buffer)
        return buffer
    }
}
