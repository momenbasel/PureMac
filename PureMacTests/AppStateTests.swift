import AppKit
import Darwin
import XCTest
@testable import PureMac

@MainActor
final class AppStateTests: XCTestCase {
    func testScanForAppFilesTracksLocationsWhileResultsArePending() throws {
        var completion: ((Set<URL>) -> Void)?
        let expectedLocations = ["/one", "/two", "/three"]
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: {
                StubLocations(paths: expectedLocations)
            },
            appFileScanner: { _, locations, pendingCompletion in
                XCTAssertEqual(locations.appSearch.paths, expectedLocations)
                completion = pendingCompletion
            }
        )

        appState.scanForAppFiles(makeApp())

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, expectedLocations.count)

        let pendingCompletion = try XCTUnwrap(completion)
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/B"),
            URL(fileURLWithPath: "/tmp/A")
        ]

        pendingCompletion(urls)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(
            appState.discoveredFiles,
            urls.sorted { $0.path < $1.path }
        )
        XCTAssertEqual(appState.selectedFiles, urls)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, urls.count)
    }

    func testSecureTrashMoverMovesThePreparedIdentityIntoTrash() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.home.appendingPathComponent("Preferences/com.example.test.plist")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("expected".utf8).write(to: source)

        let mover = SecureTrashMover(homeDirectory: fixture.home.path, userID: geteuid())
        let candidate = try mover.prepare(source)
        let destination = try mover.moveToTrash(candidate)

        guard case .missing = FileIdentity.lookup(path: source.path) else {
            return XCTFail("The prepared source entry should no longer exist")
        }
        XCTAssertEqual(FileIdentity.capture(path: destination.path), candidate.identity)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "expected")
    }

    func testSecureTrashMoverRejectsSymlinkedParentComponent() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let canary = outside.appendingPathComponent("canary")
        try Data("keep".utf8).write(to: canary)
        let linkedParent = fixture.home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)

        let mover = SecureTrashMover(homeDirectory: fixture.home.path, userID: geteuid())
        let candidate = try mover.prepare(linkedParent.appendingPathComponent("canary"))

        XCTAssertThrowsError(try mover.moveToTrash(candidate))
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "keep")
        XCTAssertTrue(try trashContents(fixture.trash).isEmpty)
    }

    func testSecureTrashMoverRejectsReplacementBeforeFinalRevalidation() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.home.appendingPathComponent("victim")
        let original = fixture.home.appendingPathComponent("original")
        let canary = fixture.home.appendingPathComponent("canary")
        try Data("original".utf8).write(to: source)
        try Data("keep".utf8).write(to: canary)

        let mover = SecureTrashMover(
            homeDirectory: fixture.home.path,
            userID: geteuid(),
            beforeRevalidation: {
                try FileManager.default.moveItem(at: source, to: original)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: canary)
            }
        )
        let candidate = try mover.prepare(source)

        XCTAssertThrowsError(try mover.moveToTrash(candidate)) { error in
            guard case SecureTrashMoveError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertEqual(FileIdentity.capture(path: original.path), candidate.identity)
        XCTAssertEqual(FileIdentity.capture(path: source.path)?.isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "keep")
        XCTAssertTrue(try trashContents(fixture.trash).isEmpty)
    }

    func testSecureTrashMoverRestoresEntryRacedAfterFinalRevalidation() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.home.appendingPathComponent("victim")
        let original = fixture.home.appendingPathComponent("original")
        let canary = fixture.home.appendingPathComponent("canary")
        try Data("original".utf8).write(to: source)
        try Data("keep".utf8).write(to: canary)

        let mover = SecureTrashMover(
            homeDirectory: fixture.home.path,
            userID: geteuid(),
            afterRevalidationBeforeRename: {
                try FileManager.default.moveItem(at: source, to: original)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: canary)
            }
        )
        let candidate = try mover.prepare(source)

        XCTAssertThrowsError(try mover.moveToTrash(candidate)) { error in
            guard case SecureTrashMoveError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
        XCTAssertEqual(FileIdentity.capture(path: original.path), candidate.identity)
        XCTAssertEqual(FileIdentity.capture(path: source.path)?.isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "keep")
        XCTAssertTrue(try trashContents(fixture.trash).isEmpty)
    }

    func testSecureTrashMoverDoesNotTreatMissingSourceAsSuccess() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let absent = fixture.home.appendingPathComponent("absent")
        let mover = SecureTrashMover(homeDirectory: fixture.home.path, userID: geteuid())

        XCTAssertThrowsError(try mover.prepare(absent)) { error in
            guard case SecureTrashMoveError.missing = error else {
                return XCTFail("Expected missing, got \(error)")
            }
        }
        XCTAssertTrue(try trashContents(fixture.trash).isEmpty)
    }

    func testSecureTrashMoverMovesFinalSymlinkWithoutFollowingTarget() throws {
        let fixture = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canary = fixture.home.appendingPathComponent("canary")
        let source = fixture.home.appendingPathComponent("link")
        try Data("keep".utf8).write(to: canary)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: canary)

        let mover = SecureTrashMover(homeDirectory: fixture.home.path, userID: geteuid())
        let candidate = try mover.prepare(source)
        let destination = try mover.moveToTrash(candidate)

        XCTAssertEqual(FileIdentity.capture(path: destination.path), candidate.identity)
        XCTAssertEqual(FileIdentity.capture(path: destination.path)?.isSymbolicLink, true)
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "keep")
    }

    private func makeApp() -> InstalledApp {
        InstalledApp(
            id: UUID(),
            appName: "PureMac",
            bundleIdentifier: "com.puremac.app",
            path: URL(fileURLWithPath: "/Applications/PureMac.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
    }

    private func makeTrashFixture() throws -> (
        root: URL,
        home: URL,
        trash: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PureMacSecureTrashTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let chmodStatus = trash.path.withCString { pointer in
            Darwin.chmod(pointer, mode_t(S_IRWXU))
        }
        guard chmodStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (root, home, trash)
    }

    private func trashContents(_ trash: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil
        )
    }
}

private final class StubLocations: Locations {
    init(paths: [String]) {
        super.init()
        appSearch = SearchCategory(name: "Apps", paths: paths)
    }
}
