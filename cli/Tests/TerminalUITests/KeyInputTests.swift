import Darwin
import XCTest
@testable import TerminalUI

final class KeyInputTests: XCTestCase {
    private func makePipe() -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        return (descriptors[0], descriptors[1])
    }

    func testReadsByteWhileOpen() {
        let (read, write) = makePipe()
        defer { close(read); close(write) }
        _ = Darwin.write(write, "a", 1)
        let input = KeyInput(descriptor: read)

        XCTAssertEqual(input.readByte(), 0x61)
        XCTAssertFalse(input.isClosed)
    }

    func testEndOfFileMarksInputClosed() {
        let (read, write) = makePipe()
        defer { close(read) }
        close(write)
        let input = KeyInput(descriptor: read)

        XCTAssertNil(input.readByte())
        XCTAssertTrue(input.isClosed)
    }

    func testReadErrorMarksInputClosed() {
        let input = KeyInput(descriptor: -1)

        XCTAssertNil(input.readByte())
        XCTAssertTrue(input.isClosed)
    }

    private func elapsedMilliseconds(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testClosedInputWaitsOutTheTimeoutAndReportsReady() {
        let (read, write) = makePipe()
        defer { close(read) }
        close(write)
        let input = KeyInput(descriptor: read)
        _ = input.readByte()
        var ready = false

        let elapsed = elapsedMilliseconds { ready = input.wait(milliseconds: 60) }

        XCTAssertTrue(ready)
        XCTAssertGreaterThanOrEqual(elapsed, 50)
    }

    func testOpenInputWaitReportsPendingByteOnly() {
        let (read, write) = makePipe()
        defer { close(read); close(write) }
        let input = KeyInput(descriptor: read)

        XCTAssertFalse(input.wait(milliseconds: 0))
        _ = Darwin.write(write, "a", 1)
        XCTAssertTrue(input.wait(milliseconds: 0))
    }
}
