import XCTest
@testable import PureMac

final class ProcessResourceMonitorTests: XCTestCase {
    private func reading(pid: Int32 = 42, start: UInt64 = 100, path: String = "/Applications/Example.app/Contents/MacOS/Example", cpu: UInt64 = 0, memory: UInt64 = 100, time: UInt64 = 1_000_000_000) -> ProcessResourceReading {
        ProcessResourceReading(pid: pid, startSeconds: start, startMicroseconds: 1,
                               executablePath: path, name: URL(fileURLWithPath: path).lastPathComponent,
                               cpuTicks: cpu, residentBytes: memory, sampledAt: time)
    }

    func testCPUIsNormalizedToTotalMachineCapacity() throws {
        let before = reading(cpu: 1_000_000_000)
        let after = reading(cpu: 3_000_000_000, time: 2_000_000_000)
        XCTAssertEqual(try XCTUnwrap(ProcessResourceMath.cpuFraction(current: after, previous: before, processorCount: 8)), 0.25, accuracy: 0.0001)
    }

    func testAppleSiliconMachTicksAreConvertedBeforeDividingByNanoseconds() throws {
        let before = reading(cpu: 0)
        let after = reading(cpu: 24_000_000, time: 2_000_000_000)
        let fraction = ProcessResourceMath.cpuFraction(current: after, previous: before,
            processorCount: 8, nanosecondsPerTick: 125.0 / 3.0)
        XCTAssertEqual(try XCTUnwrap(fraction), 0.125, accuracy: 0.0001)
    }

    func testFirstSamplePIDReuseAndCounterResetDoNotProduceFalseSpikes() {
        let before = reading(cpu: 500)
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: before, previous: nil, processorCount: 8))
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: reading(start: 101, cpu: 600, time: 2_000_000_000), previous: before, processorCount: 8))
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: reading(cpu: 10, time: 2_000_000_000), previous: before, processorCount: 8))
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: before, previous: before, processorCount: 8))
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: reading(cpu: 600, time: 2_000_000_000), previous: before, processorCount: 0))
        XCTAssertNil(ProcessResourceMath.cpuFraction(current: reading(path: "/usr/bin/other", cpu: 600, time: 2_000_000_000), previous: before, processorCount: 8))
    }

    func testNestedHelpersResolveToOutermostAppAndNonAppsStayUnattributed() {
        XCTAssertEqual(ProcessResourceMath.applicationPath(for: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "/Applications/Example.app")
        XCTAssertEqual(ProcessResourceMath.applicationPath(for: "/Users/someone/My Apps/Example.APP/Contents/XPCServices/a.xpc/a"), "/Users/someone/My Apps/Example.APP")
        XCTAssertNil(ProcessResourceMath.applicationPath(for: "/usr/local/bin/example.app-helper"))
        XCTAssertNil(ProcessResourceMath.applicationPath(for: "relative.app/helper"))
    }

    func testHelpersAggregateMemoryAndIntervalCPUWithoutMixingAppCopies() throws {
        let oldMain = reading(cpu: 100)
        let oldHelper = reading(pid: 43, path: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpu: 100)
        let main = reading(cpu: 500_000_100, memory: 200, time: 2_000_000_000)
        let helper = reading(pid: 43, path: oldHelper.executablePath, cpu: 500_000_100, memory: 300, time: 2_000_000_000)
        let copy = reading(pid: 44, path: "/Users/test/Example.app/Contents/MacOS/Example", memory: 50)
        let result = ProcessResourceMath.consumers(readings: [main, helper, copy], previous: [oldMain.identity: oldMain, oldHelper.identity: oldHelper], processorCount: 4)
        XCTAssertEqual(result.count, 2)
        let app = try XCTUnwrap(result.first { $0.applicationPath == "/Applications/Example.app" })
        XCTAssertEqual(app.name, "Example")
        XCTAssertEqual(app.processCount, 2)
        XCTAssertEqual(app.residentBytes, 500)
        XCTAssertEqual(try XCTUnwrap(app.cpuFraction), 0.25, accuracy: 0.0001)
    }

    func testUnknownPathsRemainDistinctAndNewHelperRequiresWarmup() throws {
        let first = reading(path: "")
        let second = reading(pid: 43, path: "")
        XCTAssertEqual(ProcessResourceMath.consumers(readings: [first, second], previous: [:], processorCount: 8).count, 2)
        let before = reading(cpu: 100)
        let result = ProcessResourceMath.consumers(readings: [reading(cpu: 600, time: 2_000_000_000), reading(pid: 43)], previous: [before.identity: before], processorCount: 8)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(try XCTUnwrap(result.first).cpuFraction)
    }

    func testSortingAndSearchKeepMeasuredConsumersFirstAndUseStableTies() {
        let a = ProcessResourceConsumer(id: "a", name: "Browser", applicationPath: nil, cpuFraction: 0.5, residentBytes: 100, processCount: 1)
        let b = ProcessResourceConsumer(id: "b", name: "Editor", applicationPath: nil, cpuFraction: 0.1, residentBytes: 500, processCount: 1)
        let c = ProcessResourceConsumer(id: "c", name: "Browser", applicationPath: nil, cpuFraction: nil, residentBytes: 900, processCount: 1)
        XCTAssertEqual(ProcessResourceMath.sorted([c, b, a], by: .cpu).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ProcessResourceMath.sorted([a, b, c], by: .memory).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(ProcessResourceMath.sorted([a, b, c], by: .cpu, search: " BROW ").map(\.id), ["a", "c"])
        XCTAssertTrue(ProcessResourceMath.sorted([a], by: .cpu, search: "missing").isEmpty)
        XCTAssertEqual(ProcessResourceMath.sorted([a, b], by: .cpu, search: " \n").count, 2)
        let tied = ProcessResourceConsumer(id: "d", name: a.name, applicationPath: nil, cpuFraction: a.cpuFraction, residentBytes: a.residentBytes, processCount: 1)
        XCTAssertEqual(ProcessResourceMath.sorted([tied, a], by: .cpu).map(\.id), ["a", "d"])
    }
}
