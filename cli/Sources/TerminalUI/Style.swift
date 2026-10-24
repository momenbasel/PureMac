public enum TerminalColor: Equatable {
    case red, green, yellow, cyan

    var sgrCode: Int {
        switch self {
        case .red: return 31
        case .green: return 32
        case .yellow: return 33
        case .cyan: return 36
        }
    }
}

public struct TextStyle: Equatable {
    public var color: TerminalColor?
    public var bold: Bool
    public var dim: Bool
    public var inverse: Bool

    public init(color: TerminalColor? = nil, bold: Bool = false, dim: Bool = false, inverse: Bool = false) {
        self.color = color
        self.bold = bold
        self.dim = dim
        self.inverse = inverse
    }

    public static let plain = TextStyle()

    var sgrParameters: String {
        var codes: [Int] = []
        if bold { codes.append(1) }
        if dim { codes.append(2) }
        if inverse { codes.append(7) }
        if let color { codes.append(color.sgrCode) }
        return codes.map(String.init).joined(separator: ";")
    }

    func transition(from current: TextStyle) -> String {
        guard self != current else { return "" }
        return self == .plain ? "\u{1B}[0m" : "\u{1B}[0m\u{1B}[\(sgrParameters)m"
    }
}

public struct Span: Equatable {
    public var text: String
    public var style: TextStyle

    public init(_ text: String, _ style: TextStyle = .plain) {
        self.text = text
        self.style = style
    }
}
