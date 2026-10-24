import Foundation
import XCTest
@testable import puremac
import TerminalUI

final class OptimizeConfigTests: XCTestCase {
    func testSnapshotParserAcceptsOnlyExactTimeMachineSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-13-235959.local
        com.apple.os.update-123456
        com.apple.TimeMachine.2026-02-30-120000.local
        com.apple.TimeMachine.2026-09-14-090102.local extra
        com.apple.TimeMachine.2026-09-14-090102.local
        com.apple.TimeMachine.2026-09-14-090102.local
        """

        XCTAssertEqual(
            Optimize.parseLocalSnapshots(output),
            [
                "com.apple.TimeMachine.2026-09-14-090102.local",
                "com.apple.TimeMachine.2026-09-13-235959.local",
            ]
        )
    }

    func testLegacyOptimizeViewsRemainRecognized() throws {
        XCTAssertEqual(try Optimize.parse(["ram"]).task, "ram")
        XCTAssertEqual(try Optimize.parse(["purgeable"]).task, "purgeable")
        XCTAssertEqual(try Optimize.parse(["snapshots"]).task, "snapshots")
        XCTAssertNil(try Optimize.parse([]).task)
    }

    func testUptimeFormatting() {
        XCTAssertEqual(Optimize.formatUptime(0), "0m")
        XCTAssertEqual(Optimize.formatUptime(3_661), "1h 1m")
        XCTAssertEqual(Optimize.formatUptime(176_461), "2d 1h 1m")
    }

    func testStatusSheetPlainLinesMatchTodaysLayoutExactly() {
        let memory = MemoryStatus(total: 17_179_869_184, free: 4_294_967_296, inactive: 1_073_741_824,
                                  active: 2_147_483_648, wired: 3_221_225_472, compressed: 536_870_912)
        let volume = VolumeStatus(availableNow: 107_374_182_400, availableForImportantUsage: 161_061_273_600, total: 536_870_912_000)
        let sheet = Optimize.statusSheet(memory: memory, pressure: .normal, volume: volume, machine: testMachine)
        XCTAssertEqual(sheet.plainLines(colors: false), goldenStatus)
        XCTAssertEqual(
            Optimize.statusSheet(memory: memory, pressure: nil, volume: volume, machine: testMachine).plainLines(colors: false),
            goldenStatus.filter { !$0.hasPrefix("  Pressure") }
        )
    }

    func testRamAndPurgeableSheetsPlainLinesMatchTodaysLayoutExactly() {
        let memory = MemoryStatus(total: 17_179_869_184, free: 4_294_967_296, inactive: 1_073_741_824,
                                  active: 2_147_483_648, wired: 3_221_225_472, compressed: 536_870_912)
        let volume = VolumeStatus(availableNow: 107_374_182_400, availableForImportantUsage: 161_061_273_600, total: 536_870_912_000)
        let ram = Optimize.memorySheet(memory, pressure: .normal)
        XCTAssertEqual(ram.plainLines(withHeader: false, colors: false), goldenRam)
        let purgeable = Optimize.storageSheet(volume)
        XCTAssertEqual(purgeable.plainLines(withHeader: false, colors: false), goldenPurgeable)
    }

    func testStatusViewPrintsTheSheetLinesWithoutEscapeCodes() throws {
        let output = try captureStdout { try Optimize.parse([]).run() }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.prefix(4), ["Mac status", "Read-only measurements from macOS", "", "This Mac"])
        XCTAssertEqual(lines.filter { $0 == "This Mac" || $0 == "Memory" || $0 == "Storage" }, ["This Mac", "Memory", "Storage"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("  Uptime  ") }.count, 1)
        XCTAssertEqual(lines.last(where: { !$0.isEmpty }), "No maintenance ran. Use `puremac clean --dry-run` to review removable files.")
        XCTAssertTrue(lines.allSatisfy { !$0.contains("\u{1B}") })
    }

    func testRamAndPurgeableViewsKeepTheirClosingLines() throws {
        let ram = try captureStdout { try Optimize.parse(["ram"]).run() }
        XCTAssertTrue(ram.hasPrefix("Memory\n  "))
        XCTAssertTrue(ram.contains("\n  Installed         "))
        XCTAssertTrue(ram.hasSuffix("\n\nNo memory was purged. macOS reclaims inactive memory when applications need it.\n"))
        let purgeable = try captureStdout { try Optimize.parse(["purgeable"]).run() }
        XCTAssertTrue(purgeable.hasPrefix("Storage\n  "))
        XCTAssertTrue(purgeable.contains("\n  Free now         "))
        XCTAssertTrue(purgeable.hasSuffix("\n\nNo storage was changed. APFS managed capacity is an estimate controlled by macOS.\n"))
    }

    func testManagedCapacityNeverBecomesNegative() {
        XCTAssertEqual(
            VolumeStatus(availableNow: 50, availableForImportantUsage: 80, total: 100)
                .systemManagedCapacity,
            30
        )
        XCTAssertEqual(
            VolumeStatus(availableNow: 80, availableForImportantUsage: 50, total: 100)
                .systemManagedCapacity,
            0
        )
    }

    func testConfigStoreValidatesAndPersistsToInjectedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings/config.json")

        var store = try ConfigStore(fileURL: file)
        try store.set("purge.older_than_days", " 14 ")
        XCTAssertEqual(store.values["purge.older_than_days"], "14")

        let reloaded = try ConfigStore(fileURL: file)
        XCTAssertEqual(reloaded.values["purge.older_than_days"], "14")
        XCTAssertThrowsError(try store.set("purge.older_than_days", "0"))
        XCTAssertThrowsError(try store.set("purge.older_than_days", "3651"))
        XCTAssertThrowsError(try store.set("unknown", "14"))
    }

    func testMalformedConfigAndPersistenceFailuresAreReported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed = directory.appendingPathComponent("malformed.json")
        try Data("[]".utf8).write(to: malformed)
        XCTAssertThrowsError(try ConfigStore(fileURL: malformed))

        let blocker = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocker)
        var store = try ConfigStore(fileURL: blocker.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try store.set("purge.older_than_days", "14"))
        XCTAssertTrue(store.values.isEmpty)
    }

    func testIgnoreStoreUsesInjectedFileAndRollsBackFailedSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings/ignore")
        let protected = directory.appendingPathComponent("protected").path

        var store = try IgnoreStore(fileURL: file)
        XCTAssertTrue(try store.add(protected))
        XCTAssertTrue(store.isIgnored(protected + "/child"))
        XCTAssertEqual(try IgnoreStore(fileURL: file).roots, [protected])

        let blocker = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocker)
        var blocked = try IgnoreStore(fileURL: blocker.appendingPathComponent("ignore"))
        XCTAssertThrowsError(try blocked.add(protected))
        XCTAssertTrue(blocked.roots.isEmpty)
    }

    func testRelativeIgnorePathBecomesAbsoluteAndProtectsCandidate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.appendingPathComponent("working", isDirectory: true)
        let candidate = workingDirectory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)

        var store = try IgnoreStore(
            fileURL: directory.appendingPathComponent("ignore"),
            currentDirectoryPath: workingDirectory.path
        )
        XCTAssertTrue(try store.add("./cache"))
        XCTAssertFalse(try store.add("nested/../cache"))
        XCTAssertEqual(store.roots, [candidate.path])
        XCTAssertFalse(Safety.canRemove(candidate.path, ignore: store).ok)
    }

    func testIgnoreStoreRejectsControlCharactersAndLegacyRelativeEntries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ignore")
        var store = try IgnoreStore(fileURL: file, currentDirectoryPath: directory.path)

        for path in ["", "one\ntwo", "one\rtwo", "one\0two"] {
            XCTAssertThrowsError(try store.add(path))
            XCTAssertThrowsError(try store.remove(path))
        }
        XCTAssertTrue(store.roots.isEmpty)
        var rootStore = try IgnoreStore(fileURL: file, currentDirectoryPath: "/")
        for path in [".", "/.", "/tmp/.."] {
            XCTAssertThrowsError(try rootStore.add(path))
            XCTAssertThrowsError(try rootStore.remove(path))
        }
        XCTAssertTrue(rootStore.roots.isEmpty)
        XCTAssertTrue(try rootStore.add("/tmp/./puremac-ignore-fixture"))
        XCTAssertEqual(rootStore.roots, ["/tmp/puremac-ignore-fixture"])
        XCTAssertTrue(try rootStore.remove("/tmp/puremac-ignore-fixture"))

        for contents in ["relative/path\n", "/.\n", "/tmp/..\n"] {
            try Data(contents.utf8).write(to: file)
            XCTAssertThrowsError(try IgnoreStore(fileURL: file))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class SystemStatusTests: XCTestCase {
    private let memory = MemoryStatus(
        total: 16_000_000_000, free: 4_000_000_000, inactive: 1_000_000_000,
        active: 2_000_000_000, wired: 3_000_000_000, compressed: 500_000_000
    )

    func testPressureLevelMapping() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertNil(MemoryPressure(level: 0))
        XCTAssertNil(MemoryPressure(level: 3))
        XCTAssertEqual(MemoryPressure.normal.label, "Normal")
        XCTAssertEqual(MemoryPressure.warning.color, .yellow)
        XCTAssertEqual(MemoryPressure.critical.color, .red)
        XCTAssertEqual(MemoryPressure.normal.color, .green)
    }

    func testMemoryUsedFraction() {
        XCTAssertEqual(memory.usedFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(MemoryStatus(total: 0, free: 0, inactive: 0, active: 0, wired: 0, compressed: 0).usedFraction, 0)
    }

    func testVolumeFreeColorFollowsTheFreeShare() {
        func color(free: Int64) -> TerminalColor {
            VolumeStatus(availableNow: free, availableForImportantUsage: free, total: 100).freeColor
        }
        XCTAssertEqual(color(free: 9), .red)
        XCTAssertEqual(color(free: 10), .yellow)
        XCTAssertEqual(color(free: 19), .yellow)
        XCTAssertEqual(color(free: 20), .green)
        let empty = VolumeStatus(availableNow: 0, availableForImportantUsage: 0, total: 0)
        XCTAssertEqual(empty.usedFraction, 0)
        XCTAssertEqual(empty.freeFraction, 1)
        XCTAssertEqual(empty.freeColor, .green)
        XCTAssertEqual(VolumeStatus(availableNow: 25, availableForImportantUsage: 25, total: 100).freeFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(VolumeStatus(availableNow: 25, availableForImportantUsage: 25, total: 100).usedFraction, 0.75, accuracy: 0.0001)
    }

    func testMemorySectionHasGaugeColoredByPressureThenPressureAndTodaysRows() {
        let rows = Optimize.memorySection(memory, pressure: .warning).rows
        guard case .gauge(let fraction, let color, let text) = rows[0] else { return XCTFail("gauge first") }
        XCTAssertEqual(fraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(color, .yellow)
        XCTAssertEqual(text, "11.2 GB in use of 14.9 GB")
        guard case .metric("Pressure", let value, nil) = rows[1] else { return XCTFail("pressure second") }
        XCTAssertEqual(value, [Span("Warning", TextStyle(color: .yellow))])
        XCTAssertEqual(rows.dropFirst(2).compactMap { row -> String? in
            if case .metric(let label, _, _) = row { return label }
            return nil
        }, ["Installed", "Free now", "Active", "Inactive", "Compressed", "Wired"])
    }

    func testMemorySectionWithoutPressureHasPlainGaugeAndNoPressureRow() {
        let rows = Optimize.memorySection(memory, pressure: nil).rows
        guard case .gauge(_, let color, _) = rows[0] else { return XCTFail("gauge first") }
        XCTAssertNil(color)
        XCTAssertEqual(rows.count, 7)
    }

    func testStorageSectionColorsGaugeAndFreeValueByFreeShare() {
        let volume = VolumeStatus(availableNow: 5, availableForImportantUsage: 25, total: 100)
        let rows = Optimize.storageSection(volume).rows
        guard case .gauge(let fraction, let color, let text) = rows[0] else { return XCTFail("gauge first") }
        XCTAssertEqual(fraction, 0.95, accuracy: 0.0001)
        XCTAssertEqual(color, .red)
        XCTAssertEqual(text, "\(ByteCount.human(5)) free of \(ByteCount.human(100))")
        guard case .metric("Free now", let value, nil) = rows[1] else { return XCTFail("free second") }
        XCTAssertEqual(value, [Span(ByteCount.human(5), TextStyle(color: .red))])
        XCTAssertEqual(rows.dropFirst(2).count, 3)
        guard case .message(let note) = rows[4] else { return XCTFail("note last") }
        XCTAssertEqual(note, [Span("Managed capacity may include purgeable files and is not guaranteed free space.", TextStyle(dim: true))])
    }

    func testStorageSectionOmitsTheNoteWithoutManagedCapacity() {
        let rows = Optimize.storageSection(VolumeStatus(availableNow: 50, availableForImportantUsage: 50, total: 100)).rows
        XCTAssertEqual(rows.count, 4)
    }

    func testStatusSheetHasTitleSubtitleSectionsAndFootnote() {
        let volume = VolumeStatus(availableNow: 50, availableForImportantUsage: 50, total: 100)
        let sheet = Optimize.statusSheet(memory: memory, pressure: .normal, volume: volume, machine: testMachine)
        XCTAssertEqual(sheet.title, "Mac status")
        XCTAssertEqual(sheet.subtitle, "Read-only measurements from macOS")
        XCTAssertEqual(sheet.sections.map(\.title), ["This Mac", "Memory", "Storage"])
        XCTAssertEqual(sheet.footnote, "No maintenance ran. Use `puremac clean --dry-run` to review removable files.")
    }
}

private let goldenStatus: [String] = [
    "Mac status",
    "Read-only measurements from macOS",
    "",
    "This Mac",
    "  Chip              Apple M4 Pro",
    "  Cores             14 cores (10 performance, 4 efficiency)",
    "  Memory            24 GB",
    "  macOS             26.0.1 (25A354)",
    "  Model             Mac16,7",
    "  Uptime            2d 1h 1m",
    "",
    "Memory",
    "  ███████████████░░░░░ 12 GB in use of 16 GB",
    "  Pressure          Normal",
    "  Installed         16 GB",
    "  Free now          4 GB",
    "  Active            2 GB",
    "  Inactive          1 GB",
    "  Compressed        512 MB",
    "  Wired             3 GB",
    "",
    "Storage",
    "  ████████████████░░░░ 107.4 GB free of 536.9 GB",
    "  Free now          107.4 GB",
    "  Total             536.9 GB",
    "  Managed by macOS  53.7 GB",
    "  Managed capacity may include purgeable files and is not guaranteed free space.",
    "",
    "No maintenance ran. Use `puremac clean --dry-run` to review removable files.",
]

private let goldenRam: [String] = [
    "Memory",
    "  ███████████████░░░░░ 12 GB in use of 16 GB",
    "  Pressure          Normal",
    "  Installed         16 GB",
    "  Free now          4 GB",
    "  Active            2 GB",
    "  Inactive          1 GB",
    "  Compressed        512 MB",
    "  Wired             3 GB",
    "",
    "No memory was purged. macOS reclaims inactive memory when applications need it.",
]

private let goldenPurgeable: [String] = [
    "Storage",
    "  ████████████████░░░░ 107.4 GB free of 536.9 GB",
    "  Free now          107.4 GB",
    "  Total             536.9 GB",
    "  Managed by macOS  53.7 GB",
    "  Managed capacity may include purgeable files and is not guaranteed free space.",
    "",
    "No storage was changed. APFS managed capacity is an estimate controlled by macOS.",
]

private let testMachine = MachineInfo(
    chip: "Apple M4 Pro", cores: "14 cores (10 performance, 4 efficiency)", memory: 25_769_803_776,
    macOS: "26.0.1 (25A354)", model: "Mac16,7", uptime: 176_461
)
