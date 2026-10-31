import Foundation
import XCTest
@testable import puremac

final class CleanerProgressTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func ignoreStore() throws -> IgnoreStore {
        try IgnoreStore(fileURL: directory.appendingPathComponent("ignore.json"))
    }

    private func makeItem(_ name: String) throws -> ScanItem {
        let path = directory.appendingPathComponent(name).path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return ScanItem(path: path, sizeBytes: 1, modified: nil, identity: Safety.fileIdentity(at: path))
    }

    func testCallbackRunsBeforeEachItemWithIndexCountAndItem() throws {
        let items = try (0..<3).map { try makeItem("item\($0)") }
        var calls: [(Int, Int, String, Bool)] = []

        _ = Cleaner.remove(items, ignore: try ignoreStore(), dryRun: false) { index, count, item in
            calls.append((index, count, item.path, FileManager.default.fileExists(atPath: item.path)))
        }

        XCTAssertEqual(calls.map { $0.0 }, [0, 1, 2])
        XCTAssertEqual(calls.map { $0.1 }, [3, 3, 3])
        XCTAssertEqual(calls.map { $0.2 }, items.map { $0.path })
        XCTAssertEqual(calls.map { $0.3 }, [true, true, true])
    }

    func testOutcomeIsTheSameWithAndWithoutCallback() throws {
        let items = [try makeItem("a"), try makeItem("b")]
        let plain = Cleaner.remove(items, ignore: try ignoreStore(), dryRun: true)
        let observed = Cleaner.remove(items, ignore: try ignoreStore(), dryRun: true) { _, _, _ in }
        XCTAssertEqual(observed.removed, plain.removed)
        XCTAssertEqual(observed.freedBytes, plain.freedBytes)
        XCTAssertEqual(observed.skipped.map { $0.path }, plain.skipped.map { $0.path })
        XCTAssertEqual(observed.failed.map { $0.path }, plain.failed.map { $0.path })
    }
}
