import TerminalUI

enum SizeLevel {
    case small, medium, large

    init(bytes: Int64) {
        switch bytes {
        case ..<100_000_000: self = .small
        case ..<1_000_000_000: self = .medium
        default: self = .large
        }
    }

    var color: TerminalColor {
        switch self {
        case .small: return .green
        case .medium: return .yellow
        case .large: return .red
        }
    }

    static func style(bytes: Int64, focused: Bool) -> TextStyle {
        focused ? TextStyle(inverse: true) : TextStyle(color: SizeLevel(bytes: bytes).color)
    }
}
