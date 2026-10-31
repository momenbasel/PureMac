import Darwin
import XCTest
@testable import puremac
import TerminalUI

final class AnalyzeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-analyze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func emptyIgnore() throws -> IgnoreStore {
        try IgnoreStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("analyze-ignore-\(UUID().uuidString)"))
    }

    func testDepthValidationUsesDocumentedBounds() throws {
        var analyze = Analyze()
        analyze.depth = 1
        XCTAssertNoThrow(try analyze.validate())
        analyze.depth = 8
        XCTAssertNoThrow(try analyze.validate())
        analyze.depth = 0
        XCTAssertThrowsError(try analyze.validate())
        analyze.depth = 9
        XCTAssertThrowsError(try analyze.validate())
    }

    func testDepthAndPlainModesDisableFullscreenBrowser() {
        XCTAssertTrue(Analyze.usesInteractiveBrowser(plain: false, depth: 1, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: true, depth: 1, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: false, depth: 2, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: false, depth: 1, terminalSupported: false))
    }

    func testScanRanksAllocatedSizesAndMeasuresPackageWithoutDrilldown() throws {
        let small = root.appendingPathComponent("small.bin")
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8_192).write(to: small)
        try Data(repeating: 0x42, count: 1_000_000).write(to: contents.appendingPathComponent("payload.bin"))

        let snapshot = Analyze().scanFolder(root.path, ignore: try emptyIgnore())

        XCTAssertEqual(snapshot.children.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Example.app", "small.bin"])
        let packageChild = try XCTUnwrap(snapshot.children.first)
        XCTAssertTrue(packageChild.isDir)
        XCTAssertTrue(packageChild.isPackage)
        XCTAssertGreaterThan(packageChild.size, 0)
    }

    func testScanSkipsIgnoredAndSymbolicLinkedEntries() throws {
        let visible = root.appendingPathComponent("visible.bin")
        let ignored = root.appendingPathComponent("ignored.bin")
        let link = root.appendingPathComponent("linked.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: visible)
        try Data(repeating: 0x42, count: 4_096).write(to: ignored)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: visible)

        let ignoreFile = root.appendingPathComponent("ignore-config")
        try (ignored.path + "\n").write(to: ignoreFile, atomically: true, encoding: .utf8)
        let ignore = try IgnoreStore(fileURL: ignoreFile)
        let snapshot = Analyze().scanFolder(root.path, ignore: ignore)

        XCTAssertEqual(snapshot.children.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["ignore-config", "visible.bin"])
        XCTAssertEqual(snapshot.skippedCount, 2)
        XCTAssertTrue(snapshot.isPartial)
    }

    func testUnreadableChildIsReportedAsPartialOrInaccessible() throws {
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 4_096).write(to: locked.appendingPathComponent("private.bin"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, S_IRWXU) }

        let snapshot = Analyze().scanFolder(root.path, ignore: try emptyIgnore())

        XCTAssertTrue(snapshot.isPartial)
        XCTAssertGreaterThan(snapshot.skippedCount + snapshot.inaccessibleCount, 0)
        XCTAssertFalse(snapshot.errors.isEmpty)
    }

    private func child(_ path: String, size: Int64, isDir: Bool = true, isPackage: Bool = false, skipped: Int = 0) -> Analyze.Child {
        Analyze.Child(path: path, size: size, isDir: isDir, isPackage: isPackage, inaccessibleCount: 0, skippedCount: skipped)
    }

    private func snapshot(
        path: String = "/tmp",
        children: [Analyze.Child],
        inaccessible: Int = 0,
        skipped: Int = 0,
        errors: [String] = []
    ) -> Analyze.FolderSnapshot {
        Analyze.FolderSnapshot(
            path: path,
            children: children,
            total: children.reduce(Int64(0)) { $0 + $1.size },
            inaccessibleCount: inaccessible,
            skippedCount: skipped,
            errors: errors
        )
    }

    private func manyChildren(_ count: Int) -> [Analyze.Child] {
        (0..<count).map { child("/tmp/item-\($0)", size: Int64(count - $0) * 1_024) }
    }

    func testViewportKeepsSelectionVisibleAndWithinHeight() {
        let snapshot = snapshot(children: manyChildren(20))
        let visible = Analyze.visibleRowCount(snapshot: snapshot, selected: 17, width: 60, height: 14)
        let offset = Analyze.adjustedOffset(0, selected: 17, count: 20, visibleRows: visible)
        let level = Analyze.BrowserLevel(snapshot: snapshot, selected: 17, offset: offset)
        let lines = Analyze.renderBrowser(level: level, width: 60, height: 14).plainLines()

        XCTAssertGreaterThan(offset, 0)
        XCTAssertEqual(lines.count, 14)
        XCTAssertTrue(lines.joined(separator: "\n").contains("item-17"))
    }

    func testVisibleRowCountMatchesRowsDrawn() {
        let long = "/Users/example/" + String(repeating: "deep-folder/", count: 12) + "target"
        let cases: [(Analyze.FolderSnapshot, Int, Int, Int)] = [
            (snapshot(children: manyChildren(30)), 3, 60, 24),
            (snapshot(children: manyChildren(30)), 3, 40, 12),
            (snapshot(children: [child(long, size: 4_096)] + manyChildren(30)), 0, 50, 30),
            (snapshot(children: manyChildren(30), errors: ["/tmp/x: unavailable"]), 5, 80, 20),
            (snapshot(children: [child(String(repeating: "x", count: 83), size: 10)] + manyChildren(30), errors: ["/tmp/x: unavailable"]), 0, 40, 12),
        ]
        for (snapshot, selected, width, height) in cases {
            let visible = Analyze.visibleRowCount(snapshot: snapshot, selected: selected, width: width, height: height)
            let level = Analyze.BrowserLevel(snapshot: snapshot, selected: selected)
            let lines = Analyze.renderBrowser(level: level, width: width, height: height).plainLines()
            XCTAssertEqual(lines.filter { $0.contains("█") || $0.contains("░") }.count, visible, "\(width)x\(height)")
        }
    }

    func testBrowserWindowLayout() {
        let snapshot = snapshot(
            path: "/tmp",
            children: [
                child("/tmp/alpha", size: 3_000_000),
                child("/tmp/beta.txt", size: 1_000_000, isDir: false, skipped: 1),
                child("/tmp/Gamma.app", size: 1_000_000, isPackage: true),
            ],
            skipped: 2
        )
        let lines = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot), width: 60, height: 14).plainLines()

        XCTAssertEqual(lines, [
            "╭─ PureMac Space Explorer ─────────────────────────────────╮",
            "│ /tmp                                                     │",
            "│ 5 MB allocated  ·  3 items  ·  2 skipped                 │",
            "│ › 3 MB       █████░░░ alpha/                             │",
            "│   1 MB       ██░░░░░░ beta.txt !                         │",
            "│   1 MB       ██░░░░░░ Gamma.app [package]                │",
            "│                                                          │",
            "│                                                          │",
            "│                                                          │",
            "│                                                          │",
            "├──────────────────────────────────────────────────────────┤",
            "│ Focused: /tmp/alpha                                      │",
            "│ ↑↓ move  Enter/→ open  O reveal  ←/⌫ back  q/Esc exit    │",
            "╰──────────────────────────────────────────────────────────╯",
        ])
    }

    func testFocusedRowIsInverseAcrossContentWidth() {
        let snapshot = snapshot(children: manyChildren(3))
        let buffer = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot, selected: 1), width: 60, height: 14)

        XCTAssertEqual(buffer[2, 4].style, TextStyle(color: .cyan, inverse: true))
        XCTAssertTrue((2...57).allSatisfy { buffer[$0, 4].style.inverse })
        XCTAssertFalse(buffer[1, 4].style.inverse)
        XCTAssertFalse(buffer[58, 4].style.inverse)
        XCTAssertFalse((2...57).contains { buffer[$0, 3].style.inverse || buffer[$0, 5].style.inverse })
        XCTAssertEqual(buffer[16, 4].style, TextStyle(inverse: true))
        XCTAssertTrue(buffer.lines(colors: false)[4].contains("›"))
    }

    func testGaugeUnfilledPartIsDim() {
        let snapshot = snapshot(children: [child("/tmp/a", size: 1_000), child("/tmp/b", size: 1_000)])
        let buffer = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot, selected: 1), width: 60, height: 14)
        let row = buffer.plainLines()[3]
        let filled = row.firstIndex(of: "█")!
        let empty = row.firstIndex(of: "░")!
        let column = { (index: String.Index) in Term.displayWidth(String(row[..<index])) }

        XCTAssertFalse(buffer[column(filled), 3].style.dim)
        XCTAssertTrue(buffer[column(empty), 3].style.dim)
    }

    func testSizeAndGaugeFillAreColoredByMagnitudeExceptOnFocusedRow() {
        let snapshot = snapshot(children: [
            child("/tmp/big", size: 2_000_000_000),
            child("/tmp/mid", size: 150_000_000),
            child("/tmp/small", size: 99_000_000),
        ])
        let buffer = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot, selected: 0), width: 120, height: 14)
        let gaugeColumn = { (row: Int) in
            Term.displayWidth(String(buffer.plainLines()[row].prefix { $0 != "█" && $0 != "░" }))
        }

        XCTAssertEqual(buffer[7, 3].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[gaugeColumn(3), 3].style, TextStyle(inverse: true))
        XCTAssertEqual(buffer[7, 4].style, TextStyle(color: .yellow))
        XCTAssertEqual(buffer[gaugeColumn(4), 4].style, TextStyle(color: .yellow))
        XCTAssertEqual(buffer[7, 5].style, TextStyle(color: .green))
        XCTAssertEqual(buffer[gaugeColumn(5), 5].style, TextStyle(color: .green))
    }

    func testScrollbarOnlyOverListRowsAndOnlyWhenRowsOverflow() {
        let overflowing = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(children: manyChildren(30))), width: 60, height: 14
        ).plainLines()
        let thumbRows = overflowing.indices.filter { overflowing[$0].hasSuffix("┃") }
        XCTAssertFalse(thumbRows.isEmpty)
        XCTAssertTrue(thumbRows.allSatisfy { (3..<9).contains($0) })

        let atEnd = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(children: manyChildren(30)), selected: 29, offset: 24), width: 60, height: 14
        ).plainLines()
        XCTAssertEqual(atEnd.indices.filter { atEnd[$0].hasSuffix("┃") }.max(), 9)

        let fitting = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(children: manyChildren(3))), width: 60, height: 14
        ).plainLines()
        XCTAssertFalse(fitting.contains { $0.contains("┃") })
    }

    func testHeaderStyles() {
        let buffer = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(children: manyChildren(3))), width: 60, height: 14
        )
        XCTAssertTrue(buffer[2, 1].style.bold)
        XCTAssertTrue(buffer[2, 2].style.dim)
    }

    func testVisibleRowCountKeepsAtLeastOneRowWhenTooSmall() {
        let snapshot = snapshot(children: manyChildren(3))
        XCTAssertEqual(Analyze.visibleRowCount(snapshot: snapshot, selected: 0, width: 80, height: 5), 1)
    }

    func testEmptyAndInaccessibleMessages() {
        let empty = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot(children: [])), width: 60, height: 14)
        XCTAssertEqual(empty.plainLines()[3], "│ No measurable items.                                     │")
        XCTAssertTrue(empty[2, 3].style.dim)

        let locked = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(children: [], inaccessible: 1)), width: 60, height: 14
        )
        XCTAssertTrue(locked.plainLines()[3].contains("Folder contents are inaccessible."))

        let longPath = "/" + String(repeating: "x", count: 120)
        let cramped = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(path: longPath, children: [])), width: 40, height: 12
        ).plainLines()
        XCTAssertTrue(cramped.contains { $0.hasPrefix("│ No measurable items.") })
        XCTAssertEqual(cramped.filter { $0.hasPrefix("├") }.count, 1)
        XCTAssertTrue(cramped[1].hasPrefix("│ /xxx"))
        XCTAssertTrue(cramped[1].contains("…"))
        XCTAssertTrue(cramped[1].hasSuffix("│"))
        XCTAssertTrue(cramped.last!.hasPrefix("╰"))
        XCTAssertEqual(locked[2, 3].style, TextStyle(color: .red))
    }

    func testFirstErrorIsShownInRedBelowFocusedPath() {
        let snapshot = snapshot(children: manyChildren(2), errors: ["/tmp/x: unavailable", "/tmp/y: unavailable"])
        let buffer = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot), width: 60, height: 14)
        let lines = buffer.plainLines()

        XCTAssertEqual(lines[11], "│ ! /tmp/x: unavailable                                    │")
        XCTAssertEqual(buffer[2, 11].style, TextStyle(color: .red))
        XCTAssertFalse(lines.joined().contains("/tmp/y"))
    }

    func testLongFocusedPathWrapsWithEveryCharacter() {
        let path = "/tmp/" + String(repeating: "x", count: 70)
        let snapshot = snapshot(children: [child(path, size: 10)])
        let lines = Analyze.renderBrowser(level: Analyze.BrowserLevel(snapshot: snapshot), width: 40, height: 14).plainLines()
        let wrapped = lines.filter { $0.contains("xxxx") && !$0.contains("█") }
            .map { $0.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("Focused: ") ? String($0.dropFirst(9)) : $0 }

        XCTAssertEqual(wrapped.joined(), path)
    }

    func testCrampedFocusedPathKeepsThreeListRowsAndBothPathEnds() {
        let folder = "/Users/example/Projects/client-archive/2024/reports/preview"
        let children = [child(folder + "/field-notes", size: 20_000)] + manyChildren(5)
        let lines = Analyze.renderBrowser(
            level: Analyze.BrowserLevel(snapshot: snapshot(path: folder, children: children)), width: 40, height: 12
        ).plainLines()
        let pathRows = lines.drop { !$0.contains("Focused: ") }.prefix { !$0.contains("↑↓") }
            .map { $0.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces) }
        let shownPath = pathRows.joined().replacingOccurrences(of: "Focused: ", with: "")

        XCTAssertEqual(lines.filter { $0.contains("█") || $0.contains("░") }.count, 3)
        XCTAssertTrue(shownPath.hasPrefix("/Users/example"))
        XCTAssertTrue(shownPath.hasSuffix("/preview/field-notes"))
        XCTAssertTrue(shownPath.contains("…"))
    }

    func testWideCharactersInCrampedFocusedPathKeepTheFileName() {
        let folder = "/Users/ex/" + String(repeating: "例", count: 25) + "/reports"
        let children = [child(folder + "/field-notes", size: 20_000)] + manyChildren(5)
        for height in [12, 13, 14] {
            let lines = Analyze.renderBrowser(
                level: Analyze.BrowserLevel(snapshot: snapshot(path: folder, children: children)), width: 40, height: height
            ).plainLines()
            let pathRows = lines.drop { !$0.contains("Focused: ") }.prefix { !$0.contains("↑↓") }
                .map { $0.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces) }
            let shownPath = pathRows.joined().replacingOccurrences(of: "Focused: ", with: "")

            XCTAssertTrue(shownPath.hasSuffix("/reports/field-notes"), "height \(height): \(shownPath)")
        }
    }

    func testNarrowBrowserRenderStaysWithinViewport() {
        let path = "/Users/example/a folder/with/a/very-long-name/file.bin"
        let snapshot = snapshot(path: "/Users/example/a folder", children: [child(path, size: 8_192, isDir: false)])
        let level = Analyze.BrowserLevel(snapshot: snapshot)
        let lines = Analyze.renderBrowser(level: level, width: 40, height: 12).plainLines()

        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) == 40 })
        XCTAssertTrue(lines[0].hasPrefix("╭─ PureMac Space Explorer "))
        XCTAssertTrue(lines.joined(separator: "\n").contains("O reveal"))
        XCTAssertTrue(lines.joined(separator: "\n").contains("q/Esc exit"))

        XCTAssertEqual(
            Analyze.renderBrowser(level: level, width: 39, height: 11),
            TooSmallScreen.render(title: "PureMac Space Explorer", exitHint: "Esc/q exit", width: 39, height: 11)
        )
    }

    private func measuringProgress(
        position: Int = 3, count: Int = 5, name: String = "Library", isPackage: Bool = false,
        measured: [Analyze.Child]? = nil
    ) -> Analyze.MeasureProgress {
        Analyze.MeasureProgress(
            path: "/tmp", position: position, count: count, name: name, nameIsDirectory: true,
            nameIsPackage: isPackage,
            measured: measured ?? [child("/tmp/small", size: 1_000), child("/tmp/big", size: 5_000)]
        )
    }

    private func measuringLines(
        _ progress: Analyze.MeasureProgress, drillingDown: Bool = false, width: Int = 60, height: Int = 14
    ) -> [String] {
        Analyze.renderMeasuringBrowser(
            progress: progress, tick: 2, drillingDown: drillingDown, width: width, height: height
        ).plainLines()
    }

    func testScanReportsEachChildBeforeAndAfterMeasuring() throws {
        try Data(repeating: 0x41, count: 4_096).write(to: root.appendingPathComponent("a.bin"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b-dir"), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8_192).write(to: root.appendingPathComponent("b-dir/x.bin"))

        var events: [Analyze.ScanEvent] = []
        let snapshot = Analyze().scanFolder(root.path, ignore: try emptyIgnore(), progress: { events.append($0) })

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .measuring(position: 1, count: 2, name: "a.bin", isDirectory: false, isPackage: false))
        guard case .measured(let first) = events[1] else { return XCTFail("expected measured") }
        XCTAssertEqual(URL(fileURLWithPath: first.path).lastPathComponent, "a.bin")
        XCTAssertEqual(events[2], .measuring(position: 2, count: 2, name: "b-dir", isDirectory: true, isPackage: false))
        XCTAssertEqual(snapshot, Analyze().scanFolder(root.path, ignore: try emptyIgnore()))
    }

    func testScanStopsBetweenChildrenWhenCancelled() throws {
        for name in ["a.bin", "b.bin", "c.bin"] {
            try Data(repeating: 0x41, count: 4_096).write(to: root.appendingPathComponent(name))
        }
        var measured = 0
        let snapshot = Analyze().scanFolder(
            root.path,
            ignore: try emptyIgnore(),
            progress: { if case .measured = $0 { measured += 1 } },
            isCancelled: { measured >= 1 }
        )

        XCTAssertEqual(measured, 1)
        XCTAssertEqual(snapshot.children.count, 1)
    }

    func testScanStopsInsideALargeChildWhenCancelled() throws {
        let big = root.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0..<60 {
            try Data(repeating: 0x41, count: 4_096).write(to: big.appendingPathComponent("file-\(index).bin"))
        }
        var checks = 0
        let snapshot = Analyze().scanFolder(root.path, ignore: try emptyIgnore(), isCancelled: {
            checks += 1
            return checks > 3
        })

        XCTAssertTrue(snapshot.children.isEmpty)
        XCTAssertLessThan(checks, 20)
    }

    func testMeasuringBrowserStatusReadsCancellingOnceCancelRequested() {
        let lines = Analyze.renderMeasuringBrowser(
            progress: measuringProgress(), tick: 2, drillingDown: true, isCancelling: true, width: 60, height: 14
        ).plainLines()
        XCTAssertEqual(lines[2], "│ ⠹ Cancelling…                                            │")
    }

    func testMeasureProgressCollectsEvents() {
        var progress = Analyze.MeasureProgress(path: "/tmp")
        progress.apply(.measuring(position: 2, count: 4, name: "Docs", isDirectory: true, isPackage: true))
        XCTAssertEqual(progress.position, 2)
        XCTAssertEqual(progress.count, 4)
        XCTAssertEqual(progress.name, "Docs")
        XCTAssertTrue(progress.nameIsDirectory)
        XCTAssertTrue(progress.nameIsPackage)
        progress.apply(.measured(child("/tmp/Docs", size: 10)))
        XCTAssertEqual(progress.measured.map(\.path), ["/tmp/Docs"])
    }

    func testMeasuringBrowserShowsSpinnerStatusSortedChildrenAndCurrentName() {
        let buffer = Analyze.renderMeasuringBrowser(progress: measuringProgress(), tick: 2, drillingDown: false, width: 60, height: 14)
        let lines = buffer.plainLines()

        XCTAssertEqual(lines[0], "╭─ PureMac Space Explorer ─────────────────────────────────╮")
        XCTAssertEqual(lines[1], "│ /tmp                                                     │")
        XCTAssertEqual(lines[2], "│ ⠹ Measuring 3 of 5                                       │")
        XCTAssertTrue(lines[3].contains("big/"))
        XCTAssertTrue(lines[4].contains("small/"))
        XCTAssertEqual(lines[5], "│ ⠹ Library/                                               │")
        XCTAssertTrue(buffer[2, 2].style.dim)
        XCTAssertTrue(buffer[2, 5].style.dim)
        XCTAssertFalse(lines.joined().contains("No measurable items."))
        XCTAssertFalse(buffer[2, 3].style.inverse)
    }

    func testMeasuringBrowserBeforeFirstChildAndForFiles() {
        let start = Analyze.renderMeasuringBrowser(
            progress: Analyze.MeasureProgress(path: "/tmp"), tick: 0, drillingDown: false, width: 60, height: 14
        ).plainLines()
        XCTAssertEqual(start[2], "│ ⠋ Measuring…                                             │")
        XCTAssertEqual(start[3], "│                                                          │")

        var file = measuringProgress(name: "notes.txt", measured: [])
        file.nameIsDirectory = false
        XCTAssertEqual(
            Analyze.renderMeasuringBrowser(progress: file, tick: 0, drillingDown: false, width: 60, height: 14).plainLines()[3],
            "│ ⠋ notes.txt                                              │"
        )
    }

    func testMeasuringBrowserBelowMinimumUsesTooSmallScreen() {
        XCTAssertEqual(
            Analyze.renderMeasuringBrowser(progress: measuringProgress(), tick: 0, drillingDown: false, width: 39, height: 11),
            TooSmallScreen.render(title: "PureMac Space Explorer", exitHint: "Esc/q exit", width: 39, height: 11)
        )
        XCTAssertEqual(
            Analyze.renderMeasuringBrowser(progress: measuringProgress(), tick: 0, drillingDown: true, width: 39, height: 11),
            TooSmallScreen.render(title: "PureMac Space Explorer", exitHint: "Esc back  q exit", width: 39, height: 11)
        )
    }

    func testMeasuringBrowserKeepsCurrentRowWhenMoreChildrenThanRows() {
        let many = (0..<40).map { child("/tmp/item-\($0)", size: Int64(1_000 - $0)) }
        let lines = measuringLines(measuringProgress(measured: many))
        let currentIndex = lines.firstIndex { $0.contains("⠹ Library/") }

        XCTAssertNotNil(currentIndex)
        XCTAssertTrue(lines[currentIndex! - 1].contains("item-"))
        XCTAssertTrue(lines[currentIndex! + 1].hasPrefix("├"))
        XCTAssertTrue(lines.joined().contains("item-0/"))
        XCTAssertFalse(lines.joined().contains("item-39/"))
    }

    func testMeasuringBrowserScrollbarMatchesDrawnRowsAndPathRowIsHidden() {
        let lines0 = measuringLines(measuringProgress(measured: []), width: 40, height: 12)
        XCTAssertFalse(lines0.joined().contains("Focused:"))
        let divider = lines0.firstIndex { $0.hasPrefix("├") }!
        let listRows = divider - 3
        for count in [listRows - 1, listRows, listRows + 4] {
            let many = (0..<count).map { child("/tmp/item-\($0)", size: Int64(1_000 - $0)) }
            let buffer = Analyze.renderMeasuringBrowser(
                progress: measuringProgress(measured: many), tick: 2, drillingDown: false, width: 40, height: 12
            )
            let thumb = (3..<divider).filter { buffer[39, $0].symbol == "┃" }.count
            let expected = Scrollbar(total: count, visible: listRows - 1, offset: 0).thumb(trackHeight: listRows)?.count ?? 0
            XCTAssertEqual(thumb, expected, "count \(count)")
        }
    }

    func testMeasuringBrowserShowsOnlyTheKeysThatCancel() {
        let first = measuringLines(measuringProgress()).joined(separator: "\n")
        XCTAssertTrue(first.contains("q/Esc exit"))
        XCTAssertFalse(first.contains("reveal"))
        XCTAssertFalse(first.contains("move"))

        let drill = measuringLines(measuringProgress(), drillingDown: true).joined(separator: "\n")
        XCTAssertTrue(drill.contains("←/⌫/Esc back"))
        XCTAssertTrue(drill.contains("q exit"))
        XCTAssertFalse(drill.contains("q/Esc"))
        XCTAssertFalse(drill.contains("reveal"))
    }

    func testMeasuringCurrentRowUsesPackageSuffixAndMiddleTruncation() {
        XCTAssertTrue(measuringLines(measuringProgress(name: "Foo.app", isPackage: true, measured: []))[3].contains("⠹ Foo.app [package]"))

        let long = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
        let row = measuringLines(measuringProgress(name: long, measured: []))[3]
        XCTAssertTrue(row.contains("…"))
        XCTAssertTrue(row.contains("zzz"))
        XCTAssertTrue(row.contains("aaa"))
    }

    func testMeasuringKeyActionInTheFirstScan() {
        for key in [TerminalKey.escape, .character("q"), .character("Q")] {
            XCTAssertEqual(Analyze.measuringKeyAction(key, drillingDown: false), .exit)
        }
        for key in [TerminalKey.left, .up, .enter, .backspace, .character("o")] {
            XCTAssertNil(Analyze.measuringKeyAction(key, drillingDown: false))
        }
    }

    func testMeasuringKeyActionInADrillDown() {
        for key in [TerminalKey.escape, .left, .backspace] {
            XCTAssertEqual(Analyze.measuringKeyAction(key, drillingDown: true), .back)
        }
        for key in [TerminalKey.character("q"), .character("Q")] {
            XCTAssertEqual(Analyze.measuringKeyAction(key, drillingDown: true), .exit)
        }
        for key in [TerminalKey.right, .enter, .down, .character("o")] {
            XCTAssertNil(Analyze.measuringKeyAction(key, drillingDown: true))
        }
    }
}
