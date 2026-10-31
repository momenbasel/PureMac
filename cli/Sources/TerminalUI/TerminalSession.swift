import Darwin
import Foundation

public enum TerminalKey: Equatable {
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case escape
    case space
    case tab
    case backspace
    case delete
    case character(Character)
    case unknown
}

public enum TerminalSessionError: Error {
    case unsupported
    case setupFailed
}

private var terminalSavedState = termios()
private var terminalHasSavedState = false
private var terminalSavedInputSpeed = speed_t()
private var terminalSavedOutputSpeed = speed_t()
private var terminalHasSavedSpeeds = false
private var terminalRuntimeActive = false
private var terminalPreviousSIGINT: sig_t?
private var terminalPreviousSIGTERM: sig_t?
private var terminalPreviousSIGHUP: sig_t?
private var terminalPreviousSIGQUIT: sig_t?

private func terminalWrite(_ value: String) {
    let bytes = Array(value.utf8)
    bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = Darwin.write(STDOUT_FILENO, base, buffer.count)
    }
}

private func terminalRestore() {
    if terminalHasSavedState {
        var state = terminalSavedState
        if terminalHasSavedSpeeds {
            _ = cfsetispeed(&state, terminalSavedInputSpeed)
            _ = cfsetospeed(&state, terminalSavedOutputSpeed)
        }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
    }
    if terminalRuntimeActive {
        let sequence: StaticString = "\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"
        _ = Darwin.write(STDOUT_FILENO, sequence.utf8Start, sequence.utf8CodeUnitCount)
    }
    terminalRuntimeActive = false
    terminalHasSavedState = false
    terminalHasSavedSpeeds = false
}

private func terminalSignalHandler(_ signalNumber: Int32) {
    terminalRestore()
    Darwin.signal(signalNumber, SIG_DFL)
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, signalNumber)
    pthread_sigmask(SIG_UNBLOCK, &signals, nil)
    _ = Darwin.kill(getpid(), signalNumber)
}

private func terminalExitHandler() {
    terminalRestore()
}

public final class TerminalSession {
    public static var isSupported: Bool {
        isatty(STDIN_FILENO) == 1
            && isatty(STDOUT_FILENO) == 1
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    private var isClosed = false
    private let input = KeyInput()

    public var width: Int {
        terminalDimensions().width
    }

    public var height: Int {
        terminalDimensions().height
    }

    public init() throws {
        guard Self.isSupported else {
            throw TerminalSessionError.unsupported
        }
        guard !terminalRuntimeActive else {
            throw TerminalSessionError.setupFailed
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw TerminalSessionError.setupFailed
        }

        var raw = original
        cfmakeraw(&raw)
        raw.c_lflag |= tcflag_t(ISIG)
        let disabledControl = fpathconf(STDIN_FILENO, _PC_VDISABLE)
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) {
                $0[Int(VSUSP)] = cc_t(disabledControl >= 0 ? disabledControl : 0xFF)
            }
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw TerminalSessionError.setupFailed
        }

        terminalSavedState = original
        terminalHasSavedState = true
        terminalSavedInputSpeed = cfgetispeed(&original)
        terminalSavedOutputSpeed = cfgetospeed(&original)
        terminalHasSavedSpeeds = true
        terminalRuntimeActive = true

        terminalPreviousSIGINT = Darwin.signal(SIGINT, terminalSignalHandler)
        terminalPreviousSIGTERM = Darwin.signal(SIGTERM, terminalSignalHandler)
        terminalPreviousSIGHUP = Darwin.signal(SIGHUP, terminalSignalHandler)
        terminalPreviousSIGQUIT = Darwin.signal(SIGQUIT, terminalSignalHandler)
        atexit(terminalExitHandler)

        terminalWrite("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H")
    }

    deinit {
        close()
    }

    static func frame(lines: [String], height: Int) -> String {
        let visibleLines = Array(lines.prefix(max(1, height)))
        let body = visibleLines.map { "\u{1B}[2K" + $0 }.joined(separator: "\r\n")
        return "\u{1B}[H" + body + (visibleLines.count < height ? "\u{1B}[J" : "")
    }

    public func draw(_ buffer: Buffer) {
        guard !isClosed else { return }
        terminalWrite(Self.frame(lines: buffer.lines(), height: height))
    }

    public func readKey() -> TerminalKey {
        guard !isClosed, let first = input.readByte() else { return .escape }

        if let key = Self.key(forSimpleByte: first) { return key }
        return first == 0x1B ? readEscapeSequence() : decodeCharacter(firstByte: first)
    }

    public func readKey(timeoutMilliseconds: Int) -> TerminalKey? {
        guard !isClosed else { return nil }
        let milliseconds = Int32(clamping: timeoutMilliseconds)
        guard input.wait(milliseconds: milliseconds) else { return nil }
        return readKey()
    }

    static func key(forSimpleByte byte: UInt8) -> TerminalKey? {
        switch byte {
        case 0x0A, 0x0D: return .enter
        case 0x20: return .space
        case 0x09: return .tab
        case 0x08, 0x7F: return .backspace
        case 0x01...0x1A: return .unknown
        default: return nil
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        terminalRestore()
        if let handler = terminalPreviousSIGINT { Darwin.signal(SIGINT, handler) }
        if let handler = terminalPreviousSIGTERM { Darwin.signal(SIGTERM, handler) }
        if let handler = terminalPreviousSIGHUP { Darwin.signal(SIGHUP, handler) }
        if let handler = terminalPreviousSIGQUIT { Darwin.signal(SIGQUIT, handler) }
        terminalPreviousSIGINT = nil
        terminalPreviousSIGTERM = nil
        terminalPreviousSIGHUP = nil
        terminalPreviousSIGQUIT = nil
    }

    private func readEscapeSequence() -> TerminalKey {
        guard input.available(milliseconds: 24), let second = input.readByte() else {
            return .escape
        }
        guard second == 0x5B || second == 0x4F else {
            return .escape
        }
        guard input.available(milliseconds: 24), let third = input.readByte() else {
            return .escape
        }

        switch third {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38:
            guard input.available(milliseconds: 24), let fourth = input.readByte(), fourth == 0x7E else {
                return .unknown
            }
            switch third {
            case 0x31, 0x37: return .home
            case 0x33: return .delete
            case 0x34, 0x38: return .end
            case 0x35: return .pageUp
            case 0x36: return .pageDown
            default: return .unknown
            }
        default:
            return .unknown
        }
    }

    private func decodeCharacter(firstByte: UInt8) -> TerminalKey {
        let expectedCount: Int
        switch firstByte {
        case 0x00...0x7F: expectedCount = 1
        case 0xC2...0xDF: expectedCount = 2
        case 0xE0...0xEF: expectedCount = 3
        case 0xF0...0xF4: expectedCount = 4
        default: return .unknown
        }

        var bytes = [firstByte]
        while bytes.count < expectedCount {
            guard input.available(milliseconds: 24), let byte = input.readByte() else {
                return .unknown
            }
            bytes.append(byte)
        }
        guard let string = String(bytes: bytes, encoding: .utf8), string.count == 1,
              let character = string.first else {
            return .unknown
        }
        return .character(character)
    }

    private func terminalDimensions() -> (width: Int, height: Int) {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else {
            return (80, 24)
        }
        return (max(1, Int(window.ws_col)), max(1, Int(window.ws_row)))
    }
}
