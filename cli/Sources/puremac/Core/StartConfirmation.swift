import TerminalUI

enum StartChoice: Equatable {
    case start, back
}

struct StartConfirmation {
    let title: String
    let message: String
    let menuSelection: Int

    static let explore = StartConfirmation(
        title: "Explore your home folder?",
        message: "Measuring every folder can take a few minutes.",
        menuSelection: HomeMenu.exploreIndex
    )

    static func projectCleanup(folderCount: Int) -> StartConfirmation {
        StartConfirmation(
            title: "Scan your project folders?",
            message: "Searching \(Render.counted(folderCount, "folder")) for build artifacts can take a few minutes.",
            menuSelection: HomeMenu.projectCleanupIndex
        )
    }

    private static let buttons = [DialogButton("Cancel"), DialogButton("Start")]
    static let startIndex = buttons.count - 1

    private(set) var focus = ButtonFocus(count: buttons.count, index: startIndex)

    mutating func handle(_ key: TerminalKey) -> StartChoice? {
        if focus.navigate(key) { return nil }
        switch key {
        case .enter:
            return focus.index == Self.startIndex ? .start : .back
        case .escape:
            return .back
        case .character(let character):
            switch String(character).lowercased() {
            case "s": return .start
            case "q", "n": return .back
            default: return nil
            }
        default:
            return nil
        }
    }

    func acceptsKey(_ key: TerminalKey, tooSmall: Bool) -> Bool {
        guard tooSmall else { return true }
        if key == .escape { return true }
        guard case .character(let character) = key else { return false }
        return ["q", "n"].contains(String(character).lowercased())
    }

    func render(width: Int, height: Int) -> Buffer {
        StatusScreen.overlay(dialog, on: HomeMenu.screen(selection: menuSelection, width: width, height: height), tooSmallExitHint: "Esc back")
    }

    func ask() throws -> Bool {
        let session = try TerminalSession()
        defer { session.close() }
        var model = self
        while true {
            session.draw(model.render(width: session.width, height: session.height))
            let key = session.readKey()
            let tooSmall = !TooSmallScreen.fits(width: session.width, height: session.height)
            guard model.acceptsKey(key, tooSmall: tooSmall) else { continue }
            if let choice = model.handle(key) { return choice == .start }
        }
    }

    private var dialog: Dialog {
        Dialog(
            title: title,
            message: [Span(message)],
            buttons: Self.buttons,
            focusedButton: focus.index,
            hints: StatusScreen.choiceHints
        )
    }
}
