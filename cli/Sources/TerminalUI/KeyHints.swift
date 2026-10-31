public struct KeyHint: Equatable {
    public var key: String, action: String

    public init(_ key: String, _ action: String) {
        self.key = key
        self.action = action
    }
}

public struct KeyHints {
    public var hints: [KeyHint]

    public init(_ hints: [KeyHint]) {
        self.hints = hints
    }

    public func rows(width: Int) -> [[Span]] {
        let separator = "  "
        var rows: [[Span]] = []
        var current: [Span] = []
        var used = 0
        for hint in hints {
            let spans = [Span(hint.key), Span(" " + hint.action, TextStyle(dim: true))]
            let hintWidth = Term.displayWidth(spans)
            let needed = current.isEmpty ? hintWidth : used + separator.count + hintWidth
            if !current.isEmpty, needed > width {
                rows.append(current)
                current = []
            }
            if current.isEmpty {
                used = hintWidth
            } else {
                current.append(Span(separator))
                used = needed
            }
            current += spans
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    public func render(in rect: Rect, buffer: inout Buffer) {
        for (row, spans) in rows(width: rect.width).prefix(rect.height).enumerated() {
            buffer.write(spans, x: rect.x, y: rect.y + row, maxWidth: rect.width)
        }
    }
}
