import Darwin

final class KeyInput {
    private let descriptor: Int32
    private(set) var isClosed = false

    init(descriptor: Int32 = STDIN_FILENO) {
        self.descriptor = descriptor
    }

    func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(descriptor, &byte, 1)
            if result == 1 { return byte }
            if result == -1 && errno == EINTR { continue }
            isClosed = true
            return nil
        }
    }

    func wait(milliseconds: Int32) -> Bool {
        guard !isClosed else {
            _ = poll(nil, 0, milliseconds)
            return true
        }
        return available(milliseconds: milliseconds)
    }

    func available(milliseconds: Int32) -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&pollDescriptor, 1, milliseconds) > 0
    }
}
