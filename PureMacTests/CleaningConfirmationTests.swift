import XCTest
@testable import PureMac

@MainActor
final class CleaningConfirmationTests: XCTestCase {
    func testRequestCleanAllShowsConfirmationWithoutStartingCleaning() {
        let viewModel = AppViewModel()
        let item = CleanableItem(
            name: "cache.db",
            path: "/Users/me/Library/Caches/cache.db",
            size: 20_000,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )
        viewModel.categoryResults[.userCache] = CategoryResult(
            category: .userCache,
            items: [item],
            totalSize: item.size
        )
        viewModel.totalJunkSize = item.size

        viewModel.requestCleanAll()

        XCTAssertTrue(viewModel.showCleanConfirmation)
        XCTAssertEqual(viewModel.scanState, .idle)
        XCTAssertEqual(viewModel.categoryResults[.userCache]?.items.count, 1)
        XCTAssertTrue(viewModel.cleanConfirmationMessage.contains("1 selected items"))
    }

    func testCancelCleanClearsPendingConfirmation() {
        let viewModel = AppViewModel()
        let item = CleanableItem(
            name: "cache.db",
            path: "/Users/me/Library/Caches/cache.db",
            size: 20_000,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )
        viewModel.categoryResults[.userCache] = CategoryResult(
            category: .userCache,
            items: [item],
            totalSize: item.size
        )

        viewModel.requestCleanAll()
        viewModel.cancelClean()

        XCTAssertFalse(viewModel.showCleanConfirmation)
        XCTAssertTrue(viewModel.cleanConfirmationMessage.contains("0 selected items"))
    }

    func testConfirmCleanUsesItemsCapturedAtRequestTime() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let originalURL = tempDirectory.appendingPathComponent("original.cache")
        let replacementURL = tempDirectory.appendingPathComponent("replacement.cache")
        try Data("old".utf8).write(to: originalURL)
        try Data("new".utf8).write(to: replacementURL)

        let originalItem = CleanableItem(
            name: "original.cache",
            path: originalURL.path,
            size: 3,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )
        let replacementItem = CleanableItem(
            name: "replacement.cache",
            path: replacementURL.path,
            size: 3,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )

        let viewModel = AppViewModel()
        viewModel.categoryResults[.userCache] = CategoryResult(
            category: .userCache,
            items: [originalItem],
            totalSize: originalItem.size
        )

        viewModel.requestCleanAll()
        viewModel.categoryResults[.userCache] = CategoryResult(
            category: .userCache,
            items: [replacementItem],
            totalSize: replacementItem.size
        )

        viewModel.confirmClean()

        let deadline = Date().addingTimeInterval(2)
        while fileManager.fileExists(atPath: originalURL.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(fileManager.fileExists(atPath: originalURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: replacementURL.path))
    }
}
