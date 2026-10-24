import Foundation
import XCTest
@testable import puremac
import TerminalUI

private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
}

final class ConfigSettingsTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("puremac/config.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileGivesTheDefaultDays() throws {
        XCTAssertEqual(try ConfigStore(fileURL: file).olderThanDays, 7)
    }

    func testFileWithTheDaysKeyLoads() throws {
        try write(#"{"purge.older_than_days": "14"}"#, to: file)
        XCTAssertEqual(try ConfigStore(fileURL: file).olderThanDays, 14)
    }

    func testWrongTypesAreInvalidConfigFiles() throws {
        let bad = [
            #"{"purge.roots": ["/tmp/a"]}"#,
            #"{"purge.older_than_days": 14}"#,
            "[]",
        ]
        for text in bad {
            try write(text, to: file)
            XCTAssertThrowsError(try ConfigStore(fileURL: file), text) { error in
                guard case StoreError.invalidConfigFile = error else { return XCTFail("\(text): \(error)") }
            }
        }
    }

    func testBadDaysValuesAndUnknownKeysKeepTheirValueErrors() throws {
        let bad = [
            (#"{"purge.older_than_days": "0"}"#, "invalidConfigValue"),
            (#"{"purge.older_than_days": "7", "purge.roots": "/tmp/a"}"#, "unknownConfigKey"),
            (#"{"other": "1"}"#, "unknownConfigKey"),
        ]
        for (text, name) in bad {
            try write(text, to: file)
            XCTAssertThrowsError(try ConfigStore(fileURL: file), text) { error in
                XCTAssertTrue("\(error)".hasPrefix(name), "\(text): \(error)")
            }
        }
    }

    func testDaysWithSurroundingWhitespaceAreStoredNormalized() throws {
        try write(#"{"purge.older_than_days": " 14\n"}"#, to: file)
        XCTAssertEqual(try ConfigStore(fileURL: file).olderThanDays, 14)
    }

    func testSavedFileHasOnlyTheDaysKeyPrettyPrinted() throws {
        var store = try ConfigStore(fileURL: file)
        try store.set("purge.older_than_days", "14")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\n  \"purge.older_than_days\" : \"14\"\n}")
    }

    func testRootsAreNotSettableThroughConfigSet() {
        XCTAssertThrowsError(try Config.parse(["set", "purge.roots", "/tmp/a"]))
    }

    func testEnsureDefaultsCreatesAllThreeFilesWithDefaults() throws {
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)

        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            "{\n  \"purge.older_than_days\" : \"7\"\n}"
        )
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), "")
        XCTAssertEqual(
            try String(contentsOf: projects, encoding: .utf8),
            Purger.defaultRoots.joined(separator: "\n") + "\n"
        )
        XCTAssertEqual(try ProjectFoldersStore(fileURL: projects).roots, Purger.defaultRoots)
    }

    func testDefaultConfigFilePassesTheRulesOfPureMac111() throws {
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)
        var store = try ConfigStore(fileURL: config)
        try store.set("purge.older_than_days", "30")

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config))
        let values = try XCTUnwrap(object as? [String: String])
        XCTAssertEqual(Set(values.keys), ["purge.older_than_days"])
        XCTAssertEqual(values["purge.older_than_days"], "30")
    }

    func testEnsureDefaultsNeverOverwritesExistingFiles() throws {
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        try write(#"{"purge.older_than_days": "14"}"#, to: config)
        try write("/tmp/keep\n", to: ignore)
        try write("/tmp/mine\n", to: projects)

        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)
        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), #"{"purge.older_than_days": "14"}"#)
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), "/tmp/keep\n")
        XCTAssertEqual(try String(contentsOf: projects, encoding: .utf8), "/tmp/mine\n")
    }

    func testEnsureDefaultsFillsOnlyTheMissingFile() throws {
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        try write("/tmp/keep\n", to: ignore)
        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), "/tmp/keep\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.path))
    }

    func testEnsureDefaultsLeavesAnInvalidConfigFileAlone() throws {
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        try write("[]", to: config)
        try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "[]")
    }

    func testEnsureDefaultsCreatesTheIgnoreFileEvenWhenTheConfigFileFails() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try write("x", to: blocker)
        let config = blocker.appendingPathComponent("config.json")
        let ignore = directory.appendingPathComponent("puremac/ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        XCTAssertThrowsError(try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignore.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.path))
    }

    func testEnsureDefaultsCreatesTheConfigFileEvenWhenTheIgnoreFileFails() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try write("x", to: blocker)
        let config = directory.appendingPathComponent("puremac/config.json")
        let ignore = blocker.appendingPathComponent("ignore")
        let projects = directory.appendingPathComponent("puremac/projects")
        XCTAssertThrowsError(try AppPaths.ensureDefaults(configFile: config, ignoreFile: ignore, projectsFile: projects))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.path))
    }

    func testTheWorkspaceEntryPointCreatesNothingWithoutATerminal() throws {
        try withConfigHome { dir in
            _ = try captureStdout { try PureMac.parse([]).run() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    func testPurgeWithAnEmptyFolderListSaysSoAndDoesNotScan() throws {
        try withConfigHome { _ in
            try write("", to: AppPaths.projectsFile)
            let output = try captureStdout { try Purge.parse(["--dry-run"]).run() }
            XCTAssertEqual(output, Term.dim(Purge.noFoldersMessage) + "\n")
        }
    }

    func testOtherCommandsNeverCreateTheDefaultFiles() throws {
        let scanned = directory.appendingPathComponent("scanned")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        try withConfigHome { dir in
            _ = try captureStdout { try Config.parse([]).run() }
            _ = try captureStdout { try Ignore.List.parse([]).run() }
            _ = try captureStdout { try Purge.parse([scanned.path, "--json"]).run() }
            _ = try captureStdout { try Purge.parse([scanned.path, "--dry-run"]).run() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    func testPurgeWithoutPathsScansTheConfiguredRoots() throws {
        try withConfigHome { _ in
            try write("/tmp/one\n/tmp/two\n", to: AppPaths.projectsFile)
            XCTAssertEqual(try Purge.parse([]).resolvedRoots(), ["/tmp/one", "/tmp/two"])
        }
    }

    func testPurgeWithoutPathsFallsBackToTheDefaultsWithoutAFile() throws {
        try withConfigHome { _ in
            XCTAssertEqual(try Purge.parse([]).resolvedRoots(), Purger.defaultRoots)
        }
    }

    func testPurgeWithExplicitPathsIgnoresTheProjectsFile() throws {
        try withConfigHome { _ in
            try write("[]", to: AppPaths.projectsFile)
            let explicit = directory.appendingPathComponent("explicit")
            try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
            let roots = try Purge.parse([explicit.path + "/../explicit"]).resolvedRoots()
            XCTAssertEqual(roots, [Safety.absolutePath(explicit.path)])
        }
    }

    func testConfigPlainOutputListsProjectFoldersAfterTheFiles() throws {
        try withConfigHome { dir in
            try write("\(Safety.home)/Work\n/tmp/other\n", to: AppPaths.projectsFile)
            let output = try captureStdout { try Config.parse([]).run() }
            XCTAssertEqual(output, """
            PureMac CLI settings
            Values used when a command-line option is omitted

              purge.older_than_days      7 days  default

            Files
              Settings     \(dir.path)/config.json
              Protected    \(dir.path)/ignore
              Projects     \(dir.path)/projects

            Project folders
              ~/Work
              /tmp/other

            """)
        }
    }

    func testAFileHoldingTheDefaultDaysShowsDefault() throws {
        try withConfigHome { _ in
            var store = try ConfigStore(fileURL: AppPaths.configFile)
            try store.set("purge.older_than_days", "7")
            let output = try captureStdout { try Config.parse([]).run() }
            XCTAssertTrue(output.contains("\n  purge.older_than_days      7 days  default\n"), output)
            try store.set("purge.older_than_days", "8")
            let changed = try captureStdout { try Config.parse([]).run() }
            XCTAssertTrue(changed.contains("8 days  saved"), changed)
        }
    }
}
