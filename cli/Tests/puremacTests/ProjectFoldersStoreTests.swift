import Foundation
import XCTest
@testable import puremac

final class ProjectFoldersStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("puremac/projects") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testMissingFileMeansTheDefaultFolders() throws {
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, Purger.defaultRoots)
    }

    func testEmptyFileMeansNoFolders() throws {
        try write("")
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, [])
    }

    func testLoadKeepsFileOrderAndDropsDuplicates() throws {
        try write("/tmp/b\n/tmp/a/../a\n/tmp/b/\n")
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, ["/tmp/b", "/tmp/a"])
    }

    func testInvalidLinesAreAnInvalidProjectsFile() throws {
        for text in ["relative/path\n", "/\n", "/tmp/a\n\u{0}\n"] {
            try write(text)
            XCTAssertThrowsError(try ProjectFoldersStore(fileURL: file), text) { error in
                guard case StoreError.invalidProjectsFile(file.path) = error else { return XCTFail("\(text): \(error)") }
            }
        }
    }

    func testInvalidFileMessageNamesTheProjectsFile() {
        XCTAssertEqual(
            StoreError.invalidProjectsFile("/x/projects").errorDescription,
            "Project folders file contains an invalid or relative path: /x/projects"
        )
    }

    func testAddAppendsInOrderAndRoundTrips() throws {
        try write("/tmp/z\n")
        var store = try ProjectFoldersStore(fileURL: file)
        XCTAssertTrue(try store.add("/tmp/m/"))
        XCTAssertEqual(store.roots, ["/tmp/z", "/tmp/m"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "/tmp/z\n/tmp/m\n")
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, ["/tmp/z", "/tmp/m"])
    }

    func testAddToAMissingFileKeepsTheDefaultsAndWritesThem() throws {
        var store = try ProjectFoldersStore(fileURL: file)
        XCTAssertTrue(try store.add("/tmp/new"))
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, Purger.defaultRoots + ["/tmp/new"])
    }

    func testAddingADuplicateChangesNothing() throws {
        try write("/tmp/a\n")
        var store = try ProjectFoldersStore(fileURL: file)
        XCTAssertFalse(try store.add("/tmp/b/../a"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "/tmp/a\n")
    }

    func testRelativeFoldersAreRejectedAndNothingIsSaved() throws {
        var store = try ProjectFoldersStore(fileURL: file)
        XCTAssertThrowsError(try store.add("relative")) { error in
            guard case StoreError.invalidProjectRoot("relative") = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(store.roots, Purger.defaultRoots)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidProjectRootMessageNamesTheFolder() {
        XCTAssertEqual(
            StoreError.invalidProjectRoot("relative").errorDescription,
            "Project folders must be absolute paths: relative"
        )
    }

    func testRemoveDropsTheFolderAndTheLastRemovalLeavesAnEmptyFile() throws {
        try write("/tmp/a\n/tmp/b\n")
        var store = try ProjectFoldersStore(fileURL: file)
        XCTAssertTrue(try store.remove("/tmp/a"))
        XCTAssertFalse(try store.remove("/tmp/a"))
        XCTAssertTrue(try store.remove("/tmp/b"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "")
        XCTAssertEqual(try ProjectFoldersStore(fileURL: file).roots, [])
    }

    func testFailedSaveKeepsTheFoldersInMemory() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        var store = try ProjectFoldersStore(fileURL: blocker.appendingPathComponent("projects"))
        XCTAssertThrowsError(try store.add("/tmp/a"))
        XCTAssertEqual(store.roots, Purger.defaultRoots)
    }

    func testProjectsFileLivesNextToConfigJson() {
        XCTAssertEqual(AppPaths.projectsFile.lastPathComponent, "projects")
        XCTAssertEqual(AppPaths.projectsFile.deletingLastPathComponent(), AppPaths.configDir)
    }
}
