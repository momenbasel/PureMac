import XCTest
@testable import Qpure

final class CleanupExclusionsTests: XCTestCase {
    func testExcludesChildrenAndParentDeletionButNotSiblings() {
        let excluded = ["/Users/test/Library/Caches/App/keep"]
        XCTAssertTrue(CleanupExclusions.excludes("/Users/test/Library/Caches/App", paths: excluded))
        XCTAssertTrue(CleanupExclusions.excludes("/Users/test/Library/Caches/App/keep/file", paths: excluded))
        XCTAssertFalse(CleanupExclusions.excludes("/Users/test/Library/Caches/Application", paths: excluded))
        XCTAssertFalse(CleanupExclusions.excludes("/Users/test/Library/Caches/App/keep-other", paths: excluded))
        XCTAssertFalse(CleanupExclusions.excludes("simctl-runtime:123", paths: excluded))
        XCTAssertFalse(CleanupExclusions.excludes("", paths: excluded))
    }

    func testExclusionsPersistNormalizedUniqueAbsolutePaths() throws {
        let name = "PureMacTests.Exclusions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        CleanupExclusions.add("/fixtures/data/../keep", in: defaults)
        CleanupExclusions.add("/fixtures/keep", in: defaults)
        CleanupExclusions.add("relative", in: defaults)
        XCTAssertEqual(CleanupExclusions.paths(in: defaults), ["/fixtures/keep"])
    }

    func testSymlinkAliasCannotBypassExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertTrue(CleanupExclusions.excludes(alias.appendingPathComponent("file").path, paths: [actual.path]))
        XCTAssertTrue(CleanupExclusions.excludes(actual.path, paths: [alias.path]))
    }
}
