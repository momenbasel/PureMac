import XCTest
import TerminalUI
@testable import puremac

final class ScanStatusTests: XCTestCase {
    func testStartsWithTheHeadlineAndNothingFound() {
        let status = ScanStatus(headline: "Scanning ~/Projects")
        XCTAssertEqual(status.headline, "Scanning ~/Projects")
        XCTAssertNil(status.folder)
        XCTAssertEqual(status.foundCount, 0)
        XCTAssertEqual(status.foundBytes, 0)
    }

    func testRootEventSetsTheHeadlineAndClearsTheFolder() {
        var status = ScanStatus(headline: "Scanning …", folder: "/old")
        status.apply(.root("/Users/example/Projects"))
        XCTAssertEqual(status.headline, "Scanning " + Render.shorten("/Users/example/Projects"))
        XCTAssertNil(status.folder)
    }

    func testWalkingEventSetsTheFolder() {
        var status = ScanStatus(headline: "Scanning")
        status.apply(.walking("/tmp/a/b"))
        XCTAssertEqual(status.folder, "/tmp/a/b")
    }

    func testFoundEventsAddUp() {
        var status = ScanStatus(headline: "Scanning")
        status.apply(.found(bytes: 100))
        status.apply(.found(bytes: 50))
        XCTAssertEqual(status.foundCount, 2)
        XCTAssertEqual(status.foundBytes, 150)
    }

    func testBeginCategoryNamesTheCategoryAndItsPosition() {
        var status = ScanStatus(headline: "Scanning", folder: "/old")
        status.beginCategory(title: "Developer caches", position: 2, count: 4)
        XCTAssertEqual(status.headline, "Scanning Developer caches, 2 of 4")
    }

    func testFinishedCategoryAddsItsItemsAndSize() {
        var status = ScanStatus(headline: "Scanning")
        let items = [ScanItem(path: "/tmp/a", sizeBytes: 10, modified: nil), ScanItem(path: "/tmp/b", sizeBytes: 5, modified: nil)]
        status.addFound(in: CategoryScan(id: "dev", title: "Dev", groups: [ToolGroup(tool: "npm", items: items)]))
        XCTAssertEqual(status.foundCount, 2)
        XCTAssertEqual(status.foundBytes, 15)
    }
}
