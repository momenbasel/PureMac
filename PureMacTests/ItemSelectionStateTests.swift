import XCTest
@testable import PureMac

final class ItemSelectionStateTests: XCTestCase {
    func testDefaultDeselectedItemsStartDeselected() {
        var selection = ItemSelectionState()
        let item = CleanableItem(
            name: "movie.mov",
            path: "/Users/me/Desktop/movie.mov",
            size: 200_000_000,
            category: .largeFiles,
            isSelected: false,
            lastModified: nil
        )

        XCTAssertFalse(selection.isSelected(item))
    }

    func testDefaultDeselectedItemsCanBeSelectedExplicitly() {
        var selection = ItemSelectionState()
        let item = CleanableItem(
            name: "movie.mov",
            path: "/Users/me/Desktop/movie.mov",
            size: 200_000_000,
            category: .largeFiles,
            isSelected: false,
            lastModified: nil
        )

        selection.toggle(item)

        XCTAssertTrue(selection.isSelected(item))
    }

    func testSelectAllSelectsDefaultDeselectedItems() {
        var selection = ItemSelectionState()
        let item = CleanableItem(
            name: "movie.mov",
            path: "/Users/me/Desktop/movie.mov",
            size: 200_000_000,
            category: .largeFiles,
            isSelected: false,
            lastModified: nil
        )

        selection.selectAll([item])

        XCTAssertTrue(selection.isSelected(item))
    }

    func testDeselectAllDeselectsDefaultSelectedItems() {
        var selection = ItemSelectionState()
        let item = CleanableItem(
            name: "cache.db",
            path: "/Users/me/Library/Caches/cache.db",
            size: 20_000,
            category: .userCache,
            isSelected: true,
            lastModified: nil
        )

        selection.deselectAll([item])

        XCTAssertFalse(selection.isSelected(item))
    }
}
