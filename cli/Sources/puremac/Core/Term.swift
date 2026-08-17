import Foundation

enum Term {
    static let colorEnabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isatty(fileno(stdout)) == 1
    }()

    static func style(_ s: String, _ codes: String) -> String {
        colorEnabled ? "\u{1B}[\(codes)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { style(s, "1") }
    static func dim(_ s: String) -> String { style(s, "2") }
    static func red(_ s: String) -> String { style(s, "31") }
    static func green(_ s: String) -> String { style(s, "32") }
    static func yellow(_ s: String) -> String { style(s, "33") }
    static func blue(_ s: String) -> String { style(s, "34") }
    static func cyan(_ s: String) -> String { style(s, "36") }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func confirm(_ prompt: String, default def: Bool = false) -> Bool {
        guard isatty(fileno(stdin)) == 1 else { return def }
        let hint = def ? "[Y/n]" : "[y/N]"
        print("\(prompt) \(hint) ", terminator: "")
        guard let line = readLine() else { return def }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        if answer.isEmpty { return def }
        return answer == "y" || answer == "yes"
    }

    static func bar(fraction: Double, width: Int = 24) -> String {
        let clamped = max(0, min(1, fraction))
        let filled = Int((Double(width) * clamped).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}
