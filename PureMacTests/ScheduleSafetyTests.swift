import XCTest
@testable import PureMac

final class ScheduleSafetyTests: XCTestCase {
    func testDefaultScheduledCategoriesExcludePersonalFileCategories() {
        let categories = ScheduleConfig().categoriesToScan

        XCTAssertFalse(categories.contains(.largeFiles))
        XCTAssertFalse(categories.contains(.mailAttachments))
        XCTAssertFalse(categories.contains(.purgeableSpace))
    }

    func testAutomaticCleaningCategoriesAreOnlyCacheLikeTargets() {
        XCTAssertEqual(
            CleaningCategory.automaticCleaningCategories,
            [.systemJunk, .userCache, .aiApps, .trashBins, .xcodeJunk, .brewCache]
        )
    }
}
