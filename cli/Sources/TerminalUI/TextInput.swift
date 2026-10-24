public struct TextInput: Equatable {
    public private(set) var text: String

    public init(_ text: String = "") {
        self.text = text
    }

    var isEmpty: Bool { text.isEmpty }

    mutating func insert(_ character: Character) {
        text.append(character)
    }

    mutating func backspace() {
        text = String(text.dropLast())
    }

    @discardableResult
    public mutating func handle(_ key: TerminalKey) -> Bool {
        switch key {
        case .space:
            insert(" ")
        case .backspace, .delete:
            guard !isEmpty else { return false }
            backspace()
        case .character(let character):
            guard !character.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) else { return false }
            insert(character)
        default:
            return false
        }
        return true
    }

    public func fieldSpans(label: String, width: Int) -> [Span] {
        let room = max(1, width - Term.displayWidth(label) - 1)
        let shown = Term.displayWidth(text) > room ? "…" + Term.suffix(text, width: room - 1) : text
        return [
            Span(label, TextStyle(color: .cyan)),
            Span(shown),
            Span(" ", TextStyle(inverse: true)),
        ]
    }
}
