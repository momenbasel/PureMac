import Darwin
import Foundation

public enum Term {
    private static let localeConfigured: Void = {
        setlocale(LC_CTYPE, "")
    }()

    public static var colorEnabled: Bool {
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
            && isatty(fileno(stdout)) == 1
    }

    private static func style(_ string: String, _ codes: String) -> String {
        colorEnabled ? "\u{1B}[\(codes)m\(string)\u{1B}[0m" : string
    }

    public static func bold(_ string: String) -> String { style(string, "1") }
    public static func dim(_ string: String) -> String { style(string, "2") }
    public static func red(_ string: String) -> String { style(string, "31") }
    public static func green(_ string: String) -> String { style(string, "32") }
    public static func yellow(_ string: String) -> String { style(string, "33") }
    public static func cyan(_ string: String) -> String { style(string, "36") }

    public static func err(_ string: String) {
        FileHandle.standardError.write(Data((string + "\n").utf8))
    }

    public static func confirm(_ prompt: String, default defaultValue: Bool = false) -> Bool {
        guard isatty(fileno(stdin)) == 1 else { return defaultValue }
        let hint = defaultValue ? "[Y/n]" : "[y/N]"
        print("\(sanitize(prompt)) \(hint) ", terminator: "")
        guard let line = readLine() else { return defaultValue }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        if answer.isEmpty { return defaultValue }
        return answer == "y" || answer == "yes"
    }

    static func filledCount(fraction: Double, width: Int) -> Int {
        let clamped = max(0, min(1, fraction))
        return Int((Double(max(0, width)) * clamped).rounded())
    }

    public static func sanitize(_ string: String) -> String {
        var output = ""
        output.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x20...0x7E, 0xA0...0x10FFFF:
                if scalar.value >= 0x7F && scalar.value <= 0x9F {
                    output.append("�")
                } else {
                    output.unicodeScalars.append(scalar)
                }
            case 0x09:
                output.append(" ")
            default:
                output.append("�")
            }
        }
        return output
    }

    public static func displayWidth(_ spans: [Span]) -> Int {
        spans.reduce(0) { $0 + displayWidth(sanitize($1.text)) }
    }

    public static func displayWidth(_ string: String) -> Int {
        _ = localeConfigured
        var width = 0
        var escapeState = 0
        for scalar in string.unicodeScalars {
            if escapeState == 1 {
                escapeState = scalar.value == 0x5B ? 2 : 0
                continue
            }
            if escapeState == 2 {
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    escapeState = 0
                }
                continue
            }
            if scalar.value == 0x1B {
                escapeState = 1
                continue
            }
            let scalarWidth = wcwidth(wchar_t(scalar.value))
            width += scalarWidth > 0 ? Int(scalarWidth) : 0
        }
        return width
    }

    public static func pad(_ string: String, to width: Int) -> String {
        let missing = max(0, width - displayWidth(string))
        return string + String(repeating: " ", count: missing)
    }

    public static func truncate(_ string: String, to width: Int, middle: Bool = false) -> String {
        let safe = sanitize(string)
        guard width > 0 else { return "" }
        guard displayWidth(safe) > width else { return safe }
        guard width > 1 else { return "…" }

        if middle {
            let leftWidth = (width - 1) / 2
            let rightWidth = width - 1 - leftWidth
            return prefix(safe, width: leftWidth) + "…" + suffix(safe, width: rightWidth)
        }
        return prefix(safe, width: width - 1) + "…"
    }

    private static func prefix(_ string: String, width: Int) -> String {
        var output = ""
        var used = 0
        for character in string {
            let value = String(character)
            let characterWidth = displayWidth(value)
            guard used + characterWidth <= width else { break }
            output.append(character)
            used += characterWidth
        }
        return output
    }

    static func suffix(_ string: String, width: Int) -> String {
        var characters: [Character] = []
        var used = 0
        for character in string.reversed() {
            let value = String(character)
            let characterWidth = displayWidth(value)
            guard used + characterWidth <= width else { break }
            characters.append(character)
            used += characterWidth
        }
        return String(characters.reversed())
    }
}

extension Term {
    public static func wrap(_ string: String, width: Int) -> [String] {
        let characters = sanitize(string).map { (character: $0, style: TextStyle.plain) }
        let (lines, last) = hardBreak(characters, width: width)
        return (lines + [last]).map { String($0.map(\.character)) }
    }

    static func wordWrap(_ string: String, width: Int) -> [String] {
        wordWrap([Span(string)], width: width).map { $0.map(\.text).joined() }
    }

    static func balancedWrap(_ string: String, width: Int) -> [String] {
        let lineCount = wordWrap(string, width: width).count
        let widestWord = string.split(whereSeparator: \.isWhitespace).map { displayWidth(String($0)) }.max() ?? 1
        let narrowest = (min(max(1, width), widestWord)...max(1, width)).first { wordWrap(string, width: $0).count == lineCount } ?? width
        return wordWrap(string, width: narrowest)
    }

    public static func wordWrap(_ spans: [Span], width: Int) -> [[Span]] {
        var lines: [[StyledCharacter]] = []
        var current: [StyledCharacter] = []
        var gap: [StyledCharacter] = []
        for token in wordTokens(spans) {
            guard !token.isSpaces else {
                gap = token.characters
                continue
            }
            let word = token.characters
            if displayWidth(word) <= width {
                if current.isEmpty {
                    current = word
                } else if displayWidth(current) + displayWidth(gap) + displayWidth(word) <= width {
                    current += gap + word
                } else {
                    lines.append(current)
                    current = word
                }
                continue
            }
            if !current.isEmpty { lines.append(current) }
            let (broken, last) = hardBreak(word, width: width)
            lines += broken
            current = last
        }
        lines.append(current)
        return lines.map(merged)
    }

    private typealias StyledCharacter = (character: Character, style: TextStyle)

    private static func hardBreak(_ characters: [StyledCharacter], width: Int) -> (lines: [[StyledCharacter]], last: [StyledCharacter]) {
        var lines: [[StyledCharacter]] = []
        var current: [StyledCharacter] = []
        var used = 0
        for character in characters {
            let characterWidth = displayWidth([character])
            if used + characterWidth > width && !current.isEmpty {
                lines.append(current)
                current = []
                used = 0
            }
            current.append(character)
            used += characterWidth
        }
        return (lines, current)
    }

    public static func styled(_ spans: [Span], colors: Bool = colorEnabled) -> String {
        var output = ""
        var current = TextStyle.plain
        for span in spans {
            let text = sanitize(span.text)
            guard !text.isEmpty else { continue }
            if colors { output += span.style.transition(from: current) }
            current = span.style
            output += text
        }
        return colors && current != .plain ? output + "\u{1B}[0m" : output
    }

    private static func displayWidth(_ characters: [StyledCharacter]) -> Int {
        characters.reduce(0) { $0 + max(0, displayWidth(String($1.character))) }
    }

    private static func merged(_ characters: [StyledCharacter]) -> [Span] {
        var spans: [Span] = []
        for (character, style) in characters {
            if let last = spans.last, last.style == style {
                spans[spans.count - 1].text.append(character)
            } else {
                spans.append(Span(String(character), style))
            }
        }
        return spans
    }

    private static func wordTokens(_ spans: [Span]) -> [(characters: [StyledCharacter], isSpaces: Bool)] {
        var tokens: [(characters: [StyledCharacter], isSpaces: Bool)] = []
        for span in spans {
            for character in sanitize(span.text) {
                let isSpace = character == " "
                if let last = tokens.last, last.isSpaces == isSpace {
                    tokens[tokens.count - 1].characters.append((character, span.style))
                } else {
                    tokens.append(([(character, span.style)], isSpace))
                }
            }
        }
        return tokens
    }
}
