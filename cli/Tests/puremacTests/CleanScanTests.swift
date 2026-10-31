import XCTest
import TerminalUI
@testable import puremac

final class CleanScanTests: XCTestCase {
    private func ignore() -> IgnoreStore {
        try! IgnoreStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("clean-scan-\(UUID().uuidString)"))
    }

    func testDefaultScanFiltersEmptyCategories() {
        XCTAssertTrue(Clean.scan(ids: ["none"], ignore: ignore(), progress: .silent).isEmpty)
    }

    func testStatusNamesEachCategoryWithItsPosition() {
        let status = WorkProgress(ScanStatus(headline: "Scanning"))
        _ = Clean.scan(ids: ["none", "other"], ignore: ignore(), progress: .silent, status: status)
        XCTAssertEqual(status.value.headline, "Scanning Other, 2 of 2")
    }

    func testCancelledScanStopsBeforeTheNextCategory() {
        let status = WorkProgress(ScanStatus(headline: "Scanning"))
        let cancel = CancelFlag()
        cancel.cancel()
        let result = Clean.scan(ids: ["none", "other"], ignore: ignore(), progress: .silent, status: status, cancel: cancel)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(status.value.headline, "Scanning")
    }

    func testScanCountsFoundItemsAndPassesCancelStateToTheCategoryScan() {
        let status = WorkProgress(ScanStatus(headline: "Scanning"))
        let cancel = CancelFlag()
        var cancelledSeenByScan: Bool?
        let item = ScanItem(path: "/x", sizeBytes: 500, modified: nil, identity: nil)
        let result = Clean.scan(
            ids: ["a"], ignore: ignore(), progress: .silent, status: status, cancel: cancel,
            scanCategory: { id, title, _, _, isCancelled in
                cancel.cancel()
                cancelledSeenByScan = isCancelled()
                return CategoryScan(id: id, title: title, groups: [ToolGroup(tool: "T", items: [item])])
            }
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(status.value.foundCount, 1)
        XCTAssertEqual(status.value.foundBytes, 500)
        XCTAssertEqual(cancelledSeenByScan, true)
    }
}
