public enum RowConstraint: Equatable {
    case length(Int)
    case fill
}

public struct Rect: Equatable {
    public var x, y, width, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func splitRows(_ constraints: [RowConstraint]) -> [Rect] {
        var top = y
        return Rect.sizes(constraints, total: height).map { rowHeight in
            defer { top += rowHeight }
            return Rect(x: x, y: top, width: width, height: rowHeight)
        }
    }

    public func splitColumns(_ constraints: [RowConstraint]) -> [Rect] {
        var left = x
        return Rect.sizes(constraints, total: width).map { columnWidth in
            defer { left += columnWidth }
            return Rect(x: left, y: y, width: columnWidth, height: height)
        }
    }

    private static func sizes(_ constraints: [RowConstraint], total: Int) -> [Int] {
        var remaining = max(0, total)
        let fixed: [Int?] = constraints.map { constraint in
            guard case .length(let length) = constraint else { return nil }
            let taken = min(max(0, length), remaining)
            remaining -= taken
            return taken
        }
        let fills = fixed.filter { $0 == nil }.count
        var fillIndex = 0
        return fixed.map { size in
            if let size { return size }
            defer { fillIndex += 1 }
            return remaining / fills + (fillIndex < remaining % fills ? 1 : 0)
        }
    }
}

public struct Cell: Equatable {
    public var symbol: String
    public var style: TextStyle

    static let blank = Cell(symbol: " ", style: .plain)
}

public struct Buffer: Equatable {
    public let width: Int
    public let height: Int
    private var cells: [Cell]

    public var area: Rect { Rect(x: 0, y: 0, width: width, height: height) }

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        cells = Array(repeating: .blank, count: self.width * self.height)
    }

    public subscript(x: Int, y: Int) -> Cell {
        cells[index(x: x, y: y)]
    }

    @discardableResult
    public mutating func write(_ text: String, x: Int, y: Int, style: TextStyle = .plain, maxWidth: Int = .max) -> Int {
        write([Span(text, style)], x: x, y: y, maxWidth: maxWidth)
    }

    @discardableResult
    public mutating func write(_ spans: [Span], x: Int, y: Int, maxWidth: Int = .max) -> Int {
        guard (0..<height).contains(y), (0..<width).contains(x), maxWidth > 0 else { return 0 }
        let limit = x + min(maxWidth, width - x)
        var column = x
        for span in spans {
            for character in Term.sanitize(span.text) {
                let characterWidth = Term.displayWidth(String(character))
                guard column + characterWidth <= limit else { return column - x }
                for offset in 0..<characterWidth {
                    clearWideNeighbor(of: column + offset, y: y)
                    cells[index(x: column + offset, y: y)] = Cell(
                        symbol: offset == 0 ? String(character) : "",
                        style: span.style
                    )
                }
                column += characterWidth
            }
        }
        return column - x
    }

    public mutating func clear(_ rect: Rect) {
        let left = max(0, rect.x)
        let right = min(width, rect.x + rect.width)
        let top = max(0, rect.y)
        let bottom = min(height, rect.y + rect.height)
        guard right > left, bottom > top else { return }
        let blanks = String(repeating: " ", count: right - left)
        for row in top..<bottom {
            write(blanks, x: left, y: row)
        }
    }

    public mutating func fade() {
        let dim = TextStyle(dim: true)
        cells = cells.map { Cell(symbol: $0.symbol, style: dim) }
    }

    public func lines(colors: Bool = Term.colorEnabled) -> [String] {
        (0..<height).map { row in
            var line = ""
            var current = TextStyle.plain
            for column in 0..<width {
                let cell = cells[index(x: column, y: row)]
                if colors {
                    line += cell.style.transition(from: current)
                    current = cell.style
                }
                line += cell.symbol
            }
            if colors, current != .plain {
                line += "\u{1B}[0m"
            }
            return line
        }
    }

    public func plainLines() -> [String] {
        lines(colors: false)
    }

    private func index(x: Int, y: Int) -> Int {
        precondition((0..<width).contains(x) && (0..<height).contains(y), "cell out of buffer")
        return y * width + x
    }

    private mutating func clearWideNeighbor(of column: Int, y: Int) {
        let index = index(x: column, y: y)
        if cells[index].symbol == "", column > 0 {
            cells[index - 1] = .blank
        }
        if column + 1 < width, cells[index + 1].symbol == "" {
            cells[index + 1] = .blank
        }
    }
}
