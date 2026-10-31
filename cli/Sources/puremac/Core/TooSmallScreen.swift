import TerminalUI

enum TooSmallScreen {
    static let minimumWidth = 40
    static let minimumHeight = 12

    static func fits(width: Int, height: Int) -> Bool {
        width >= minimumWidth && height >= minimumHeight
    }

    static func render(title: String, exitHint: String, width: Int, height: Int) -> Buffer {
        var buffer = Buffer(width: width, height: height)
        let rows: [(String, TextStyle)] = [
            (title, TextStyle(color: .cyan, bold: true)),
            ("Terminal too small", .plain),
            ("Resize to at least \(minimumWidth) x \(minimumHeight)", TextStyle(dim: true)),
            ("", .plain),
            (exitHint, TextStyle(dim: true))
        ]
        for (row, (text, style)) in rows.enumerated() {
            buffer.write(Term.truncate(text, to: width), x: 0, y: row, style: style)
        }
        return buffer
    }
}
