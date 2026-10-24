import TerminalUI

enum FocusPointer {
    static func span(focused: Bool) -> Span {
        Span(focused ? "›" : " ", TextStyle(color: focused ? .cyan : nil, inverse: focused))
    }
}
