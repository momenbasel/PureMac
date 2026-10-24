import XCTest
@testable import puremac

final class PurgerScanTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        let provisional = fileManager.temporaryDirectory
            .appendingPathComponent("puremac-purger-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: provisional, withIntermediateDirectories: true)
        root = provisional.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testDefaultScanGroupsByProjectAndSortsBySize() throws {
        let large = try artifact("alpha/node_modules", bytes: 16_384)
        let medium = try artifact("beta/target", bytes: 8192)
        let small = try artifact("beta/src/.build", bytes: 4096)
        try fileManager.createDirectory(at: root.appendingPathComponent("beta/plain"), withIntermediateDirectories: true)

        let scan = Purger.scan(roots: [root.path], olderThanDays: 0, ignore: try ignoreStore())

        XCTAssertEqual(scan.id, "purge")
        XCTAssertEqual(scan.title, "Project Artifacts")
        XCTAssertEqual(scan.groups.map(\.tool), ["alpha", "beta"])
        XCTAssertEqual(scan.groups.map { $0.items.map { canonical($0.path) } }, [[canonical(large.path)], [canonical(medium.path), canonical(small.path)]])
        XCTAssertEqual(scan.groups.flatMap(\.items).map(\.sizeBytes), [16_384, 8192, 4096])
        XCTAssertTrue(scan.groups.flatMap(\.items).allSatisfy(\.selected))
    }

    func testCancelledArtifactMeasurementIsNotReportedAsAGroup() throws {
        let modules = try artifact("alpha/node_modules", bytes: 4096)
        for index in 0..<60 { try Data(repeating: 1, count: 4096).write(to: modules.appendingPathComponent("file-\(index).bin")) }
        var checks = 0

        let scan = Purger.scan(roots: [root.path], olderThanDays: 0, ignore: try ignoreStore(), isCancelled: {
            checks += 1
            return checks > 2
        })

        XCTAssertTrue(scan.groups.isEmpty)
        XCTAssertLessThan(checks, 20)
    }

    func testRecentArtifactsStayUnselectedAndEmptyOnesAreSkipped() throws {
        try artifact("alpha/node_modules", bytes: 8192)
        try fileManager.createDirectory(at: root.appendingPathComponent("alpha/venv"), withIntermediateDirectories: true)

        let scan = Purger.scan(roots: [root.path], olderThanDays: 7, ignore: try ignoreStore())

        XCTAssertEqual(scan.groups.flatMap(\.items).map(\.selected), [false])
    }

    func testProgressReportsRootsWalkedFoldersAndFoundArtifacts() throws {
        try artifact("alpha/node_modules", bytes: 8192)
        var events: [PurgeScanEvent] = []

        _ = Purger.scan(roots: [root.path], olderThanDays: 0, ignore: try ignoreStore(), progress: { events.append($0) })

        XCTAssertEqual(events.first, .root(canonical(root.path)))
        let canonicalEvents = events.map { event -> PurgeScanEvent in
            switch event {
            case .root(let path): .root(canonical(path))
            case .walking(let path): .walking(canonical(path))
            case .found(let bytes): .found(bytes: bytes)
            }
        }
        XCTAssertTrue(canonicalEvents.contains(.walking(canonical(root.appendingPathComponent("alpha").path))))
        XCTAssertTrue(canonicalEvents.contains(.found(bytes: 8192)))
    }

    func testProgressDoesNotChangeTheResult() throws {
        try artifact("alpha/node_modules", bytes: 16_384)
        try artifact("beta/target", bytes: 8192)
        let ignore = try ignoreStore()

        let plain = Purger.scan(roots: [root.path], olderThanDays: 3, ignore: ignore)
        let reported = Purger.scan(roots: [root.path], olderThanDays: 3, ignore: ignore, progress: { _ in }, isCancelled: { false })

        XCTAssertEqual(plain.groups.map(\.tool), reported.groups.map(\.tool))
        XCTAssertEqual(plain.groups.flatMap(\.items).map(\.path), reported.groups.flatMap(\.items).map(\.path))
        XCTAssertEqual(plain.groups.flatMap(\.items).map(\.selected), reported.groups.flatMap(\.items).map(\.selected))
    }

    func testCancelledBeforeStartingFindsNothing() throws {
        try artifact("alpha/node_modules", bytes: 8192)
        var events: [PurgeScanEvent] = []

        let scan = Purger.scan(
            roots: [root.path], olderThanDays: 0, ignore: try ignoreStore(),
            progress: { events.append($0) }, isCancelled: { true }
        )

        XCTAssertTrue(scan.groups.isEmpty)
        XCTAssertFalse(events.contains { if case .found = $0 { true } else { false } })
    }

    func testCancelStopsTheWalkAfterTheFirstFind() throws {
        try artifact("alpha/node_modules", bytes: 8192)
        try artifact("beta/target", bytes: 8192)
        var found = 0

        let scan = Purger.scan(
            roots: [root.path], olderThanDays: 0, ignore: try ignoreStore(),
            progress: { if case .found = $0 { found += 1 } }, isCancelled: { found >= 1 }
        )

        XCTAssertEqual(found, 1)
        XCTAssertEqual(scan.groups.flatMap(\.items).count, 1)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    private func artifact(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("file.bin"))
        return url
    }

    private func ignoreStore() throws -> IgnoreStore {
        try IgnoreStore(fileURL: root.appendingPathComponent("config/ignore"))
    }
}
