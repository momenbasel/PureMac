public struct DialogButton: Equatable {
    public enum Role: Equatable { case normal, destructive }

    public var title: String
    public var role: Role

    public init(_ title: String, role: Role = .normal) {
        self.title = title
        self.role = role
    }
}

public struct Dialog {
    public enum MessageAlignment: Equatable { case center, leading }

    public var title: String
    public var titleStyle: TextStyle
    public var borderStyle: TextStyle
    public var message: [Span]
    public var buttons: [DialogButton]
    public var focusedButton: Int?
    public var hints: KeyHints?
    public var messageAlignment: MessageAlignment

    public init(
        title: String,
        titleStyle: TextStyle = TextStyle(bold: true),
        borderStyle: TextStyle = .plain,
        message: [Span] = [],
        buttons: [DialogButton] = [],
        focusedButton: Int? = nil,
        hints: KeyHints? = nil,
        messageAlignment: MessageAlignment = .center
    ) {
        self.title = title
        self.titleStyle = titleStyle
        self.borderStyle = borderStyle
        self.message = message
        self.buttons = buttons
        self.focusedButton = focusedButton
        self.hints = hints
        self.messageAlignment = messageAlignment
    }

    private static let sidePadding = 1
    private static let titleMargin = 2

    public static func maxContentWidth(in area: Rect) -> Int {
        max(1, area.width - 8 - 2 * Dialog.sidePadding)
    }

    public static func maxTitleWidth(in area: Rect) -> Int {
        max(1, maxContentWidth(in: area) - titleMargin)
    }

    public func frame(in area: Rect) -> Rect {
        placement(in: area).frame
    }

    public func render(in area: Rect, buffer: inout Buffer) {
        let (frame, layout) = placement(in: area)
        buffer.clear(frame)
        let inner = Window(title: title, borderStyle: borderStyle, titleStyle: titleStyle)
            .render(in: frame, buffer: &buffer)
        let content = Rect(x: inner.x + Dialog.sidePadding, y: inner.y, width: max(0, inner.width - 2 * Dialog.sidePadding), height: inner.height)
        var row = content.y + layout.blankAboveFirst
        for message in layout.messageRows {
            renderMessage(message, in: content, row: row, buffer: &buffer)
            row += 1
        }
        row += layout.blankBelowMessage
        for spans in buttonRows(width: content.width) {
            renderCentered(spans, in: content, row: row, buffer: &buffer)
            row += 1
        }
        row += layout.blankBelowButtons
        for spans in hints?.rows(width: content.width) ?? [] {
            renderCentered(spans, in: content, row: row, buffer: &buffer)
            row += 1
        }
    }

    private struct Layout {
        var messageRows: [Span]
        var blankAboveFirst = 0
        var blankBelowMessage = 0
        var blankBelowButtons = 0
        var blankBelowLast = 0
        var hintRows: Int
        var buttonRows: Int
        var height: Int {
            messageRows.count + blankAboveFirst + blankBelowMessage + blankBelowButtons + blankBelowLast + buttonRows + hintRows
        }
    }

    private func placement(in area: Rect) -> (frame: Rect, layout: Layout) {
        let contentWidth = self.contentWidth(maxWidth: Dialog.maxContentWidth(in: area))
        let layout = layout(contentWidth: contentWidth, maxRows: area.height - 4)
        let width = contentWidth + 4 + 2 * Dialog.sidePadding
        let height = layout.height + 2
        let frame = Rect(
            x: area.x + (area.width - width) / 2,
            y: area.y + (area.height - height) / 2,
            width: width,
            height: height
        )
        return (frame, layout)
    }

    private func buttonSpan(_ index: Int) -> Span {
        let button = buttons[index]
        let title = Term.sanitize(button.title)
        let style = TextStyle(color: button.role == .destructive ? .red : nil, inverse: index == focusedButton)
        return Span(index == focusedButton ? "› \(title) ‹" : "[ \(title) ]", style)
    }

    private func buttonRows(width: Int) -> [[Span]] {
        guard !buttons.isEmpty else { return [] }
        let spans = buttons.indices.map(buttonSpan)
        let sideBySide = spans.enumerated().flatMap { $0.offset == 0 ? [$0.element] : [Span("  "), $0.element] }
        return Term.displayWidth(sideBySide) <= width ? [sideBySide] : spans.map { [$0] }
    }

    private func contentWidth(maxWidth: Int) -> Int {
        let titleWidth = Term.displayWidth(Term.sanitize(title)) + Dialog.titleMargin
        let messageWidth = message.map { Term.displayWidth(Term.sanitize($0.text)) }.max() ?? 0
        let buttonsWidth = buttonRows(width: maxWidth).map(Term.displayWidth).max() ?? 0
        let hintWidth = hints?.rows(width: .max).first.map(Term.displayWidth) ?? 0
        return max(1, min(max(titleWidth, messageWidth, buttonsWidth, hintWidth), maxWidth))
    }

    private func layout(contentWidth: Int, maxRows: Int) -> Layout {
        let hintRows = hints?.rows(width: contentWidth).count ?? 0
        let buttonRows = self.buttonRows(width: contentWidth).count
        let tailRows = buttonRows + hintRows
        let wrapped = message.flatMap { paragraph in
            wrap(paragraph.text, width: contentWidth).map { Span($0, paragraph.style) }
        }
        var layout = Layout(messageRows: wrapped, hintRows: hintRows, buttonRows: buttonRows)
        let hasGroups = !wrapped.isEmpty || tailRows > 0
        layout.blankAboveFirst = hasGroups ? 1 : 0
        layout.blankBelowMessage = !wrapped.isEmpty && tailRows > 0 ? 1 : 0
        layout.blankBelowButtons = buttonRows > 0 && hintRows > 0 ? 1 : 0
        layout.blankBelowLast = hasGroups ? 1 : 0
        if layout.height > maxRows { layout.blankBelowLast = 0 }
        if layout.height > maxRows { layout.blankBelowButtons = 0 }
        if layout.height > maxRows { layout.blankBelowMessage = 0 }
        if layout.height > maxRows { layout.blankAboveFirst = 0 }
        layout.messageRows = Array(wrapped.prefix(max(0, maxRows - layout.height + wrapped.count)))
        return layout
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        messageAlignment == .center ? Term.balancedWrap(text, width: width) : Term.wordWrap(text, width: width)
    }

    private func renderCentered(_ spans: [Span], in content: Rect, row: Int, buffer: inout Buffer) {
        let width = Term.displayWidth(spans)
        let column = content.x + max(0, content.width - width) / 2
        buffer.write(spans, x: column, y: row, maxWidth: content.x + content.width - column)
    }

    private func renderMessage(_ span: Span, in content: Rect, row: Int, buffer: inout Buffer) {
        switch messageAlignment {
        case .center:
            renderCentered([span], in: content, row: row, buffer: &buffer)
        case .leading:
            buffer.write([span], x: content.x, y: row, maxWidth: content.width)
        }
    }
}
