import TerminalUI

struct ButtonFocus {
    let count: Int
    private(set) var index: Int

    mutating func move(_ delta: Int) {
        index = min(count - 1, max(0, index + delta))
    }

    mutating func cycle() {
        index = (index + 1) % count
    }

    mutating func navigate(_ key: TerminalKey) -> Bool {
        switch key {
        case .left: move(-1)
        case .right: move(1)
        case .tab: cycle()
        default: return false
        }
        return true
    }
}
