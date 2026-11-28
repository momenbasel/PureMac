import XCTest
@testable import PureMac

@MainActor
final class MonitoringLifecycleTests: XCTestCase {
    func testRepeatedActivationDoesNotLeakSubscriptionsAndLastOwnerStopsSampling() {
        var samples = 0
        let monitor = SystemMonitor(sampleAction: { samples += 1 })
        let page = UUID()
        monitor.start(owner: page, interval: 1.5)
        monitor.start(owner: page, interval: 1.5)
        XCTAssertEqual(samples, 1)
        XCTAssertTrue(monitor.isSampling)
        monitor.stop(owner: page)
        XCTAssertFalse(monitor.isSampling)
        monitor.stop(owner: page)
        XCTAssertFalse(monitor.isSampling)
    }

    func testLeavingPerformanceKeepsOnlyMenuBarIntervalUntilMenuBarStops() {
        let monitor = SystemMonitor(sampleAction: {})
        let page = UUID(), menuBar = UUID(), popover = UUID()
        monitor.start(owner: menuBar)
        monitor.start(owner: page, interval: 1.5)
        monitor.start(owner: popover)
        XCTAssertEqual(monitor.samplingInterval, 1.5)
        monitor.stop(owner: page)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.samplingInterval, 2)
        monitor.stop(owner: popover)
        XCTAssertTrue(monitor.isSampling)
        monitor.stop(owner: menuBar)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertNil(monitor.samplingInterval)
    }

    func testQueuedTimerCannotSampleAfterLastOwnerLeaves() async throws {
        var samples = 0
        let monitor = SystemMonitor(sampleAction: { samples += 1 })
        let owner = UUID()
        monitor.start(owner: owner, interval: 0.1)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(samples, 1)
        monitor.stop(owner: owner)
        let stoppedCount = samples
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(samples, stoppedCount)
    }

    func testResourceHistoryUsesMeasuredDeltasAndPausesWithItsOwner() async throws {
        let monitor = SystemMonitor()
        let owner = UUID()
        monitor.start(owner: owner, interval: 0.1)
        defer { monitor.stop(owner: owner) }
        let first = try XCTUnwrap(monitor.latestReading)
        XCTAssertNil(first.cpu)
        XCTAssertGreaterThan(first.totalMemory, 0)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(first.memory)))

        for _ in 0..<50 where monitor.latestReading?.cpu == nil {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let measured = try XCTUnwrap(monitor.latestReading)
        XCTAssertGreaterThan(measured.date, first.date)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(measured.cpu)))

        monitor.stop(owner: owner)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(monitor.latestReading?.date, measured.date)
    }

    func testPausingKeepsTheLastSampleAndResumingResetsTheBaseline() async throws {
        let monitor = ProcessResourceMonitor()
        monitor.setActive(true)
        for _ in 0..<100 where monitor.consumers.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(monitor.consumers.isEmpty, "Native read-only sample should include this test host")
        let shown = monitor.consumers.map(\.id)
        monitor.setActive(false)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertEqual(monitor.consumers.map(\.id), shown, "Pausing keeps the last sample on screen")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.consumers.map(\.id), shown, "Cancelled work must not publish after pausing")
        monitor.setActive(true)
        XCTAssertTrue(monitor.isWarmingUp, "Resuming starts from a fresh baseline")
        XCTAssertEqual(monitor.consumers.map(\.id), shown, "The last sample stays until the next one arrives")
        monitor.setActive(false)
    }
}
