import TerminalUI

struct SystemStatusScreen {
    struct Panel {
        var section: InfoSection
        var window: Window

        init(section: InfoSection, info: Span? = nil) {
            self.section = section
            window = Window(title: section.title ?? "", info: info?.text)
            if let style = info?.style { window.infoStyle = style }
        }
    }

    static let title = "System status"
    private static let hints = KeyHints([KeyHint("↑↓", "scroll"), KeyHint("Esc", "back")])
    private static let sideBySideWidth = 80
    private static let frame = Window(title: "")

    private static func inset(width: Int) -> Rect {
        frame.contentRect(in: Rect(x: 0, y: 0, width: width, height: 3))
    }

    private static var chromeRows: Int { 3 - inset(width: 3).height }

    var thisMac: Panel
    var memory: Panel
    var storage: Panel

    static func make(
        machine: MachineInfo,
        memory: Result<MemoryStatus, Error>,
        pressure: MemoryPressure?,
        volume: Result<VolumeStatus, Error>
    ) -> SystemStatusScreen {
        SystemStatusScreen(
            thisMac: Panel(section: Optimize.thisMacSection(machine)),
            memory: panel(
                Optimize.memoryTitle, memory,
                section: { Optimize.memorySection($0, pressure: pressure) },
                info: { _ in pressure.map { Span($0.label, TextStyle(color: $0.color, bold: true)) } }
            ),
            storage: panel(
                Optimize.storageTitle, volume,
                section: Optimize.storageSection,
                info: { Span("\(Int($0.freeFraction * 100))% free", TextStyle(color: $0.freeColor, bold: true)) }
            )
        )
    }

    static func current() -> SystemStatusScreen {
        make(
            machine: SystemInfo.machine(),
            memory: Result { try SystemInfo.memoryStatus() },
            pressure: SystemInfo.memoryPressure(),
            volume: Result { try SystemInfo.volumeStatus("/") }
        )
    }

    static func run(in session: TerminalSession) {
        let screen = current()
        var scroll = InfoSheetScroll()
        while true {
            session.draw(screen.render(width: session.width, height: session.height, offset: scroll.offset))
            if scroll.handle(session.readKey(), maxOffset: screen.maxOffset(width: session.width, height: session.height)) { return }
        }
    }

    func render(width: Int, height: Int, offset: Int) -> Buffer {
        guard TooSmallScreen.fits(width: width, height: height) else {
            return TooSmallScreen.render(title: Self.title, exitHint: "Esc back", width: width, height: height)
        }
        var buffer = Buffer(width: width, height: height)
        let layout = layout(width: width, height: height)
        let start = max(0, min(offset, layout.maxOffset))
        for (panel, rect, lines) in layout.panels {
            let shifted = Rect(x: rect.x, y: rect.y - start, width: rect.width, height: rect.height)
            let content = panel.window.render(in: shifted, buffer: &buffer)
            for (index, spans) in lines.enumerated() {
                InfoSheet.write(spans, in: Rect(x: content.x, y: content.y + index, width: content.width, height: 1), buffer: &buffer)
            }
        }
        let inset = Self.inset(width: width)
        for (index, spans) in layout.footnote.enumerated() {
            buffer.write(spans, x: inset.x, y: layout.footnoteTop + index - start, maxWidth: inset.width)
        }
        buffer.clear(layout.footer)
        if layout.scrolls {
            Scrollbar(total: layout.total, visible: layout.viewport, offset: start)
                .render(column: width - 1, rows: 0..<layout.viewport, buffer: &buffer)
        }
        Self.hints.render(in: Rect(x: inset.x, y: layout.footer.y, width: inset.width, height: layout.footer.height), buffer: &buffer)
        return buffer
    }

    func maxOffset(width: Int, height: Int) -> Int {
        guard TooSmallScreen.fits(width: width, height: height) else { return 0 }
        return layout(width: width, height: height).maxOffset
    }

    private struct Layout {
        var panels: [(panel: Panel, rect: Rect, lines: [[Span]])]
        var footnote: [[Span]]
        var footnoteTop: Int
        var viewport: Int
        var footer: Rect
        var scrolls: Bool
        var total: Int { footnoteTop + footnote.count }
        var maxOffset: Int { max(0, total - viewport) }
    }

    private func layout(width: Int, height: Int) -> Layout {
        let full = layout(width: width, height: height, panelWidth: width)
        return full.maxOffset > 0 ? layout(width: width, height: height, panelWidth: width - 1) : full
    }

    private func layout(width: Int, height: Int, panelWidth: Int) -> Layout {
        let footerRows = Self.hints.rows(width: Self.inset(width: width).width).count
        let viewport = max(0, height - footerRows)
        let sideBySide = width >= Self.sideBySideWidth
        let groups = sideBySide ? [[thisMac], [memory, storage]] : [[thisMac], [memory], [storage]]
        var panels: [(panel: Panel, rect: Rect, lines: [[Span]])] = []
        var top = 0
        for group in groups {
            let columns = Rect(x: 0, y: top, width: panelWidth, height: 1).splitColumns(group.map { _ in .fill })
            let lines = zip(group, columns).map { panel, column in
                let width = panel.window.contentRect(in: Rect(x: column.x, y: top, width: column.width, height: Self.chromeRows + 1)).width
                return panel.section.rows.flatMap { InfoSheet.lines($0, labelWidth: panel.section.labelWidth, indent: "", wrappingTo: width) }
            }
            let panelHeight = (lines.map(\.count).max() ?? 0) + Self.chromeRows
            for (index, panel) in group.enumerated() {
                let column = columns[index]
                panels.append((panel, Rect(x: column.x, y: top, width: column.width, height: panelHeight), lines[index]))
            }
            top += panelHeight
        }
        let note = [Span(Optimize.statusFootnote, TextStyle(dim: true))]
        return Layout(
            panels: panels,
            footnote: Term.wordWrap(note, width: max(1, Self.inset(width: panelWidth).width)),
            footnoteTop: top,
            viewport: viewport,
            footer: Rect(x: 0, y: viewport, width: width, height: footerRows),
            scrolls: panelWidth < width
        )
    }

    private static func panel<Value>(
        _ title: String,
        _ result: Result<Value, Error>,
        section: (Value) -> InfoSection,
        info: (Value) -> Span?
    ) -> Panel {
        switch result {
        case .success(let value):
            return Panel(section: section(value), info: info(value))
        case .failure(let error):
            let message = Span(error.localizedDescription, TextStyle(color: .red))
            return Panel(section: InfoSection(title: title, rows: [.message([message])]))
        }
    }
}

extension InfoSheet {
    static func write(_ spans: [Span], in rect: Rect, buffer: inout Buffer) {
        guard Term.displayWidth(spans) > rect.width else {
            buffer.write(spans, x: rect.x, y: rect.y, maxWidth: rect.width)
            return
        }
        let used = buffer.write(spans, x: rect.x, y: rect.y, maxWidth: rect.width - 1)
        buffer.write("…", x: rect.x + used, y: rect.y)
    }
}

struct InfoSheetScroll {
    private(set) var offset = 0

    mutating func handle(_ key: TerminalKey, maxOffset: Int) -> Bool {
        switch key {
        case .up: offset = max(0, min(offset, maxOffset) - 1)
        case .down: offset = min(maxOffset, offset + 1)
        case .escape, .enter, .left, .backspace: return true
        case .character(let character): return character.lowercased() == "q"
        default: break
        }
        return false
    }
}
