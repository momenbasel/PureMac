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

    func testProcessMonitorStopsAndReleasesItsVisibleData() async throws {
        let monitor = ProcessResourceMonitor()
        monitor.setActive(true)
        for _ in 0..<100 where monitor.consumers.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(monitor.consumers.isEmpty, "Native read-only sample should include this test host")
        monitor.setActive(false)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.consumers.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(monitor.consumers.isEmpty, "Cancelled work must not publish after hiding")
    }
}
