import Foundation
import XCTest
@testable import puremac
import TerminalUI

final class MachineInfoTests: XCTestCase {
    private let strings = [
        "machdep.cpu.brand_string": "Apple M4 Pro",
        "hw.model": "Mac16,7",
        "kern.osversion": "25A354",
    ]
    private let ints: [String: Int64] = [
        "hw.perflevel0.physicalcpu": 10,
        "hw.perflevel1.physicalcpu": 4,
        "hw.ncpu": 14,
        "hw.memsize": 25_769_803_776,
    ]

    private func machine(
        strings: [String: String]? = nil,
        ints: [String: Int64]? = nil,
        version: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)
    ) -> MachineInfo {
        let strings = strings ?? self.strings
        let ints = ints ?? self.ints
        return SystemInfo.machine(sysctl: Sysctl(string: { strings[$0] }, int: { ints[$0] }), version: version, uptime: 3_661)
    }

    func testFormatsFactsFromInjectedValues() {
        XCTAssertEqual(machine(), MachineInfo(
            chip: "Apple M4 Pro",
            cores: "14 cores (10 performance, 4 efficiency)",
            memory: 25_769_803_776,
            macOS: "26.0.1 (25A354)",
            model: "Mac16,7",
            uptime: 3_661
        ))
    }

    func testFallsBackToLogicalCoreCountWithoutPerformanceLevels() {
        var ints = self.ints
        ints["hw.perflevel1.physicalcpu"] = nil
        XCTAssertEqual(machine(ints: ints).cores, "14 cores")
        ints["hw.ncpu"] = 1
        XCTAssertEqual(machine(ints: ints).cores, "1 core")
    }

    func testMissingValuesAreNilAndZeroPatchIsHidden() {
        let info = machine(strings: [:], ints: [:], version: OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0))
        XCTAssertEqual(info, MachineInfo(chip: nil, cores: nil, memory: nil, macOS: "15.2", model: nil, uptime: 3_661))
    }

    func testSystemReaderFindsRealKeysAndRejectsUnknownOnes() {
        XCTAssertNotNil(Sysctl.system.string("hw.model"))
        XCTAssertNotNil(Sysctl.system.int("hw.memsize"))
        XCTAssertNotNil(Sysctl.system.int("hw.ncpu"))
        XCTAssertNil(Sysctl.system.string("puremac.no.such.key"))
        XCTAssertNil(Sysctl.system.int("puremac.no.such.key"))
    }

    func testThisMacSectionListsRowsInOrderAndOmitsMissingOnes() {
        let section = Optimize.thisMacSection(machine())
        XCTAssertEqual(section.title, "This Mac")
        XCTAssertEqual(section.rows.map(label), ["Chip", "Cores", "Memory", "macOS", "Model", "Uptime"])
        let sparse = Optimize.thisMacSection(MachineInfo(chip: nil, cores: nil, memory: nil, macOS: "15.2", model: nil, uptime: 60))
        XCTAssertEqual(sparse.rows.map(label), ["macOS", "Uptime"])
    }

    private func label(_ row: InfoRow) -> String? {
        guard case .metric(let label, _, _) = row else { return nil }
        return label
    }
}

final class SystemStatusScreenTests: XCTestCase {
    private let machine = MachineInfo(
        chip: "Apple M4 Pro", cores: "14 cores (10 performance, 4 efficiency)", memory: 25_769_803_776,
        macOS: "26.0.1 (25A354)", model: "Mac16,7", uptime: 176_461
    )
    private let memory = MemoryStatus(
        total: 17_179_869_184, free: 4_294_967_296, inactive: 1_073_741_824,
        active: 2_147_483_648, wired: 3_221_225_472, compressed: 536_870_912
    )
    private let volume = VolumeStatus(availableNow: 107_374_182_400, availableForImportantUsage: 161_061_273_600, total: 536_870_912_000)

    private func screen(pressure: MemoryPressure? = .normal) -> SystemStatusScreen {
        SystemStatusScreen.make(machine: machine, memory: .success(memory), pressure: pressure, volume: .success(volume))
    }

    private func lines(width: Int, height: Int, offset: Int = 0) -> [String] {
        screen().render(width: width, height: height, offset: offset).plainLines()
    }

    func testWideTerminalPutsMemoryAndStorageSideBySideUnderThisMac() {
        let lines = lines(width: 100, height: 30)
        XCTAssertEqual(lines.count, 30)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 100 })
        XCTAssertTrue(lines[0].hasPrefix("╭─ This Mac "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("╮"))
        let panelTops = lines.filter { $0.contains("╭─ Memory ") }
        XCTAssertEqual(panelTops.count, 1)
        XCTAssertTrue(panelTops[0].contains("╮╭─ Storage "), panelTops[0])
        XCTAssertTrue(panelTops[0].contains(" Normal ─╮"), panelTops[0])
        XCTAssertTrue(panelTops[0].contains(" 20% free ─╮"), panelTops[0])
    }

    func testRowsSitOneColumnInsideTheFrameWithoutExtraIndent() {
        let lines = lines(width: 100, height: 30)
        XCTAssertTrue(lines[1].hasPrefix("│ Chip "), lines[1])
        let gauge = lines.first { $0.contains("12 GB in use") }
        XCTAssertTrue(gauge?.hasPrefix("│ █") == true, gauge ?? "")
    }

    func testEachSideBySidePanelTakesHalfTheWidth() {
        let line = lines(width: 81, height: 30).first { $0.contains("╭─ Memory ") }
        XCTAssertEqual(line?.range(of: "╭─ Storage").map { line!.distance(from: line!.startIndex, to: $0.lowerBound) }, 41)
    }

    func testEightyColumnsIsTheFirstSideBySideWidth() {
        let wide = lines(width: 80, height: 40)
        let top = wide.first { $0.contains("╭─ Memory ") }
        XCTAssertTrue(top?.contains("╮╭─ Storage ") == true, top ?? "")
        XCTAssertEqual(wide.filter { $0.contains("╯╰") }.count, 1)
        XCTAssertFalse(lines(width: 79, height: 60).contains { $0.contains("╯╰") })
    }

    func testStorageTitleShowsTheFlooredPercentSoItNeverCrossesTheColorThreshold() {
        func info(availableNow: Int64) -> (text: String, color: TerminalColor?) {
            let volume = VolumeStatus(availableNow: availableNow, availableForImportantUsage: availableNow, total: 1_000)
            let screen = SystemStatusScreen.make(machine: machine, memory: .success(memory), pressure: .normal, volume: .success(volume))
            let buffer = screen.render(width: 100, height: 30, offset: 0)
            let lines = buffer.plainLines()
            let top = lines.firstIndex { $0.contains("╭─ Storage ") }!
            let range = lines[top].range(of: #"\d+% free"#, options: .regularExpression)!
            let column = lines[top].distance(from: lines[top].startIndex, to: range.lowerBound)
            return (String(lines[top][range]), buffer[column, top].style.color)
        }
        XCTAssertEqual(info(availableNow: 196).text, "19% free")
        XCTAssertEqual(info(availableNow: 196).color, .yellow)
        XCTAssertEqual(info(availableNow: 96).text, "9% free")
        XCTAssertEqual(info(availableNow: 96).color, .red)
    }

    func testNarrowTerminalStacksThePanels() {
        let lines = lines(width: 79, height: 50)
        let tops = lines.enumerated().filter { $0.element.hasPrefix("╭") }
        XCTAssertEqual(tops.count, 3)
        XCTAssertTrue(tops[1].element.hasPrefix("╭─ Memory "))
        XCTAssertTrue(tops[2].element.hasPrefix("╭─ Storage "))
        XCTAssertFalse(lines.contains { $0.contains("╮╭") })
    }

    func testPanelsHoldTheFactsAndTheFootnoteAndHintsFollow() {
        let lines = lines(width: 100, height: 30)
        let text = lines.joined(separator: "\n")
        for fact in ["Chip", "Apple M4 Pro", "14 cores (10 performance, 4 efficiency)", "26.0.1 (25A354)", "Mac16,7", "2d 1h 1m",
                     "12 GB in use of 16 GB", "Wired", "107.4 GB free of 536.9 GB", "Managed by macOS"] {
            XCTAssertTrue(text.contains(fact), fact)
        }
        let footnote = lines.firstIndex { $0.contains(Optimize.statusFootnote) }
        let lastBottom = lines.lastIndex { $0.hasPrefix("╰") }
        XCTAssertNotNil(footnote)
        XCTAssertLessThan(lastBottom ?? 0, footnote ?? 0)
        XCTAssertTrue(lines.last?.hasPrefix("  ↑↓ scroll") == true, lines.last ?? "")
        XCTAssertTrue(lines.last?.contains("Esc back") == true)
        XCTAssertEqual(lines[footnote ?? 0].prefix(2), "  ")
    }

    func testScrollbarThumbIsOneContinuousRunAndFramesStayWhole() {
        let screen = screen()
        for (width, height) in [(80, 12), (60, 14), (40, 12)] {
            for offset in 0...screen.maxOffset(width: width, height: height) {
                let lines = screen.render(width: width, height: height, offset: offset).plainLines().dropLast()
                let rows = lines.enumerated().filter { $0.element.hasSuffix("┃") }.map(\.offset)
                XCTAssertFalse(rows.isEmpty, "\(width)x\(height) offset \(offset)")
                XCTAssertEqual(rows.count, (rows.last ?? 0) - (rows.first ?? 0) + 1, "\(width)x\(height) offset \(offset)")
                XCTAssertFalse(lines.contains { String($0.dropLast()).hasSuffix("┃") }, "\(width)x\(height) offset \(offset)")
            }
        }
    }

    func testStylesLabelsDimAndPressureAndFreeInfoInTheirColors() {
        let buffer = screen(pressure: .warning).render(width: 100, height: 30, offset: 0)
        let lines = buffer.plainLines()
        let chip = lines.firstIndex { $0.contains("Chip") }!
        let column = lines[chip].distance(from: lines[chip].startIndex, to: lines[chip].range(of: "Chip")!.lowerBound)
        XCTAssertTrue(buffer[column, chip].style.dim)
        let top = lines.firstIndex { $0.contains("╭─ Memory ") }!
        let warning = lines[top].distance(from: lines[top].startIndex, to: lines[top].range(of: "Warning")!.lowerBound)
        XCTAssertEqual(buffer[warning, top].style.color, .yellow)
        let free = lines[top].distance(from: lines[top].startIndex, to: lines[top].range(of: "20% free")!.lowerBound)
        XCTAssertEqual(buffer[free, top].style.color, .green)
    }

    func testMemoryPanelHasNoInfoWithoutPressure() {
        let top = screen(pressure: nil).render(width: 100, height: 30, offset: 0).plainLines().first { $0.contains("╭─ Memory ") }
        XCTAssertFalse(top?.contains("Normal") == true)
        XCTAssertTrue(top?.contains("╭─ Memory ─") == true)
    }

    func testErrorsShowInRedInsideTheirPanel() {
        struct Failure: LocalizedError { var errorDescription: String? { "no memory data" } }
        let broken = SystemStatusScreen.make(machine: machine, memory: .failure(Failure()), pressure: nil, volume: .success(volume))
        let buffer = broken.render(width: 100, height: 30, offset: 0)
        let lines = buffer.plainLines()
        let row = lines.firstIndex { $0.contains("no memory data") }!
        let column = lines[row].distance(from: lines[row].startIndex, to: lines[row].range(of: "no memory")!.lowerBound)
        XCTAssertEqual(buffer[column, row].style.color, .red)
        XCTAssertTrue(lines.contains { $0.contains("107.4 GB free of 536.9 GB") })
    }

    func testScrollsWholeScreenWhenContentDoesNotFit() {
        let screen = screen()
        let width = 60, height = 14
        let maxOffset = screen.maxOffset(width: width, height: height)
        XCTAssertGreaterThan(maxOffset, 0)
        let top = screen.render(width: width, height: height, offset: 0).plainLines()
        let bottom = screen.render(width: width, height: height, offset: maxOffset).plainLines()
        XCTAssertTrue(top[0].hasPrefix("╭─ This Mac "))
        XCTAssertFalse(bottom[0].hasPrefix("╭─ This Mac "))
        XCTAssertTrue(bottom.contains { $0.contains(Optimize.statusFootnote.prefix(20)) })
        XCTAssertEqual(screen.render(width: width, height: height, offset: maxOffset + 9).plainLines(), bottom)
        for lines in [top, bottom] {
            XCTAssertTrue(lines.last?.contains("↑↓ scroll") == true)
            XCTAssertTrue(lines.dropLast().contains { $0.hasSuffix("┃") })
        }
    }

    func testNoScrollbarOrOffsetWhenEverythingFits() {
        let screen = screen()
        XCTAssertEqual(screen.maxOffset(width: 100, height: 60), 0)
        XCTAssertFalse(screen.render(width: 100, height: 60, offset: 0).plainLines().contains { $0.contains("┃") })
    }

    func testBelowMinimumUsesTooSmallScreen() {
        XCTAssertEqual(
            screen().render(width: 39, height: 20, offset: 0),
            TooSmallScreen.render(title: "System status", exitHint: "Esc back", width: 39, height: 20)
        )
        XCTAssertEqual(
            screen().render(width: 80, height: 11, offset: 0),
            TooSmallScreen.render(title: "System status", exitHint: "Esc back", width: 80, height: 11)
        )
        XCTAssertEqual(screen().maxOffset(width: 39, height: 20), 0)
    }

    func testHomeMenuStatusEntryIsSystemStatus() {
        XCTAssertEqual(HomeMenu.options[HomeMenu.statusIndex].title, "System status")
    }

    func testWriteCutsAnOverlongRowWithAnEllipsis() {
        var buffer = Buffer(width: 10, height: 1)
        InfoSheet.write([Span(String(repeating: "a", count: 30))], in: Rect(x: 0, y: 0, width: 10, height: 1), buffer: &buffer)
        XCTAssertEqual(buffer.plainLines(), ["aaaaaaaaa…"])
        var fits = Buffer(width: 10, height: 1)
        InfoSheet.write([Span("short")], in: Rect(x: 0, y: 0, width: 10, height: 1), buffer: &fits)
        XCTAssertEqual(fits.plainLines()[0].trimmingCharacters(in: .whitespaces), "short")
    }

    func testScrollMovesByOneAndStaysInRange() {
        var scroll = InfoSheetScroll()
        XCTAssertFalse(scroll.handle(.up, maxOffset: 3))
        XCTAssertEqual(scroll.offset, 0)
        for _ in 0..<5 { XCTAssertFalse(scroll.handle(.down, maxOffset: 3)) }
        XCTAssertEqual(scroll.offset, 3)
        XCTAssertFalse(scroll.handle(.up, maxOffset: 3))
        XCTAssertEqual(scroll.offset, 2)
        XCTAssertFalse(scroll.handle(.down, maxOffset: 0))
        XCTAssertEqual(scroll.offset, 0)
    }

    func testScrollClosesOnEscQEnterLeftAndBackspace() {
        for key in [TerminalKey.escape, .enter, .left, .backspace, .character("q"), .character("Q")] {
            var scroll = InfoSheetScroll()
            XCTAssertTrue(scroll.handle(key, maxOffset: 3), "\(key)")
        }
    }

    func testScrollIgnoresOtherKeys() {
        for key in [TerminalKey.right, .tab, .space, .pageDown, .character("x"), .unknown] {
            var scroll = InfoSheetScroll()
            XCTAssertFalse(scroll.handle(key, maxOffset: 3), "\(key)")
            XCTAssertEqual(scroll.offset, 0)
        }
    }
}
