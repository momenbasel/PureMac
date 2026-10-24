import XCTest
@testable import puremac

final class CommandReviewTests: XCTestCase {
    func testReadOnlyModesOverrideForceAndNeverRequireTerminal() {
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: true,
                dryRun: true,
                json: false,
                plain: false,
                terminalSupported: false,
                inputIsTTY: false
            ),
            .reportOnly
        )
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: true,
                dryRun: false,
                json: true,
                plain: false,
                terminalSupported: false,
                inputIsTTY: false
            ),
            .reportOnly
        )
    }

    func testNoninteractiveDeletionFailsClosedUnlessForced() {
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: false,
                dryRun: false,
                json: false,
                plain: false,
                terminalSupported: true,
                inputIsTTY: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: true,
                dryRun: false,
                json: false,
                plain: false,
                terminalSupported: false,
                inputIsTTY: false
            ),
            .forced
        )
    }

    func testUnsupportedFullscreenTerminalUsesPlainReview() {
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: false,
                dryRun: false,
                json: false,
                plain: false,
                terminalSupported: false,
                inputIsTTY: true
            ),
            .plain
        )
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: false,
                dryRun: false,
                json: false,
                plain: true,
                terminalSupported: true,
                inputIsTTY: true
            ),
            .plain
        )
        XCTAssertEqual(
            CleanupCommandPolicy.mode(
                force: false,
                dryRun: false,
                json: false,
                plain: false,
                terminalSupported: true,
                inputIsTTY: true
            ),
            .fullscreen
        )
    }

    func testPlainSelectionSupportsRangesAllAndNone() throws {
        XCTAssertEqual(try PlainSelectionReview.parseSelection("1, 3-5 7", itemCount: 7), [1, 3, 4, 5, 7])
        XCTAssertEqual(try PlainSelectionReview.parseSelection("all", itemCount: 3), [1, 2, 3])
        XCTAssertEqual(try PlainSelectionReview.parseSelection("none", itemCount: 3), [])
        XCTAssertEqual(try PlainSelectionReview.parseSelection("", itemCount: 0), [])
        XCTAssertThrowsError(try PlainSelectionReview.parseSelection("0,4", itemCount: 3))
        XCTAssertThrowsError(try PlainSelectionReview.parseSelection("3-1", itemCount: 3))
    }

    func testPlainReviewCanSelectRecentPurgeItemAndFreezesOnlyChosenPaths() {
        let old = ScanItem(path: "/tmp/project/old/node_modules", sizeBytes: 100, modified: nil, selected: true)
        let recent = ScanItem(path: "/tmp/project/recent/node_modules", sizeBytes: 200, modified: nil, selected: false)
        let category = CategoryScan(
            id: "purge",
            title: "Project Artifacts",
            groups: [ToolGroup(tool: "node_modules", items: [old, recent])]
        )

        let reviewed = PlainSelectionReview.applyingSelection([2], to: [category])

        XCTAssertEqual(reviewed.flatMap(\.selectedItems).map(\.path), [recent.path])
        XCTAssertEqual(category.selectedItems.map(\.path), [old.path])
    }

    func testCleanAndPurgeHelpDescribeTheConfirmationDialogAndPlainReview() throws {
        for discussion in [Clean.configuration.discussion, Purge.configuration.discussion] {
            XCTAssertTrue(discussion.contains(Render.reviewHelp), discussion)
            XCTAssertTrue(discussion.contains("Return on the selection screen opens a confirmation with Cancel focused"))
            XCTAssertTrue(discussion.contains("--plain uses a numbered selector with ranges, all, and none, then prints the exact deletion review and asks (default No)"))
            XCTAssertFalse(discussion.contains("only opens an exact deletion review"))
        }
    }
}
