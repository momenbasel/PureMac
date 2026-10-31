public struct Scrollbar {
    public var total: Int, visible: Int, offset: Int

    public init(total: Int, visible: Int, offset: Int) {
        self.total = total
        self.visible = visible
        self.offset = offset
    }

    public static func centeredOffset(total: Int, visible: Int, focus: Int) -> Int {
        max(0, min(max(0, total - visible), focus - visible / 2))
    }

    public func thumb(trackHeight: Int) -> Range<Int>? {
        guard total > visible, trackHeight > 0 else { return nil }
        let length = max(1, Int((Double(trackHeight * visible) / Double(total)).rounded()))
        let travel = total - visible
        let clamped = max(0, min(travel, offset))
        let start = Int((Double((trackHeight - length) * clamped) / Double(travel)).rounded())
        return start..<(start + length)
    }

    public func render(column x: Int, rows: Range<Int>, buffer: inout Buffer, style: TextStyle = .plain) {
        guard let thumb = thumb(trackHeight: rows.count) else { return }
        for row in thumb {
            buffer.write("┃", x: x, y: rows.lowerBound + row, style: style)
        }
    }
}
