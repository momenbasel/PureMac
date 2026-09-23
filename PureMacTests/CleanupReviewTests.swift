import XCTest
@testable import Qpure

final class CleanupReviewTests: XCTestCase {
    func testCombinedFiltersUseNameOrPathSizeAndAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        let items = [
            item("Archive", path: "/work/project/archive", size: 2_000_000_000, date: old),
            item("PROJECT", size: 1_500_000_000, date: now),
            item("project", size: 5, date: old),
            item("project", size: 3_000_000_000, date: nil)
        ]
        let filter = CleanupReviewFilter(query: " Project ", size: .gigabyte1, age: .month)
        XCTAssertEqual(filter.apply(to: items, now: now).map(\.id), [items[0].id])
    }

    func testSortUsesStableTiesAndUnknownDatesLast() {
        let a = item("Alpha", size: 100, date: Date(timeIntervalSince1970: 1))
        let b = item("Beta", size: 100, date: nil)
        let c = item("Charlie", size: 200, date: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(CleanupReviewFilter().apply(to: [b, c, a]).map(\.name), ["Charlie", "Alpha", "Beta"])
        XCTAssertEqual(CleanupReviewFilter(order: .oldest).apply(to: [b, c, a]).map(\.name), ["Alpha", "Charlie", "Beta"])
    }

    private func item(_ name: String, path: String = "/fixture", size: Int64, date: Date?) -> CleanableItem {
        CleanableItem(name: name, path: path, size: size, category: .largeFiles, isSelected: false, lastModified: date)
    }
}
