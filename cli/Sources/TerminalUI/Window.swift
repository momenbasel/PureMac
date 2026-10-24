public struct Window {
    public var title: String
    public var info: String?
    public var borderStyle: TextStyle
    public var titleStyle: TextStyle
    public var infoStyle: TextStyle

    public init(
        title: String,
        info: String? = nil,
        borderStyle: TextStyle = TextStyle(dim: true),
        titleStyle: TextStyle = TextStyle(color: .cyan, bold: true),
        infoStyle: TextStyle = TextStyle(bold: true)
    ) {
        self.title = title
        self.info = info
        self.borderStyle = borderStyle
        self.titleStyle = titleStyle
        self.infoStyle = infoStyle
    }

    @discardableResult
    public func render(in rect: Rect, buffer: inout Buffer) -> Rect {
        guard rect.width >= 2, rect.height >= 2 else { return contentRect(in: rect) }
        let right = rect.x + rect.width - 1
        let bottom = rect.y + rect.height - 1
        buffer.write(horizontalBorder("╭", "╮", width: rect.width), x: rect.x, y: rect.y, style: borderStyle)
        buffer.write(horizontalBorder("╰", "╯", width: rect.width), x: rect.x, y: bottom, style: borderStyle)
        for row in (rect.y + 1)..<bottom {
            buffer.write("│", x: rect.x, y: row, style: borderStyle)
            buffer.write("│", x: right, y: row, style: borderStyle)
        }
        renderTitle(in: rect, buffer: &buffer)
        return contentRect(in: rect)
    }

    public func contentRect(in rect: Rect) -> Rect {
        guard rect.width >= 2, rect.height >= 2 else {
            return Rect(x: rect.x, y: rect.y, width: 0, height: 0)
        }
        return Rect(
            x: rect.x + 2,
            y: rect.y + 1,
            width: max(0, rect.width - 4),
            height: max(0, rect.height - 2)
        )
    }

    public func renderDivider(atRow y: Int, in rect: Rect, buffer: inout Buffer) {
        guard rect.width >= 2 else { return }
        buffer.write(horizontalBorder("├", "┤", width: rect.width), x: rect.x, y: y, style: borderStyle)
    }

    private func horizontalBorder(_ left: String, _ right: String, width: Int) -> String {
        left + String(repeating: "─", count: width - 2) + right
    }

    private func renderTitle(in rect: Rect, buffer: inout Buffer) {
        let infoText = info.map(Term.sanitize)
        var titleSpace = rect.width - 6
        if let infoText {
            let infoWidth = Term.displayWidth(infoText)
            let withInfo = rect.width - 9 - infoWidth
            if withInfo >= 4 {
                titleSpace = withInfo
                let infoColumn = rect.x + rect.width - 4 - infoWidth
                buffer.write([Span(" "), Span(infoText, infoStyle), Span(" ")], x: infoColumn, y: rect.y)
            }
        }
        let text = Term.truncate(title, to: titleSpace)
        if !text.isEmpty {
            buffer.write([Span(" "), Span(text, titleStyle), Span(" ")], x: rect.x + 2, y: rect.y)
        }
    }
}
