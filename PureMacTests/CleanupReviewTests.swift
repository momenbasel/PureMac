import XCTest
@testable import PureMac

final class CleanupReviewTests: XCTestCase {
    @MainActor
    func testMailDownloadsInBothRootsRequireIndividualSelection() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("PureMac-Mail-" + UUID().uuidString)
        let document = root.appendingPathComponent("Library/Mail Downloads/Meeting.key")
        let invoice = root.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/Invoice.pdf")
        let contents = Data(repeating: 0x42, count: 4096)
        for url in [document, invoice] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        addTeardownBlock { try files.removeItem(at: root) }

        let result = await ScanEngine(homeDirectory: root).scanCategory(.mailAttachments)
        XCTAssertEqual(Set(result.items.map(\.name)), ["Meeting.key", "Invoice.pdf"])
        XCTAssertEqual(result.totalSize, 8192)
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelected && $0.selectOnlyByHand })

        let state = AppState(performStartupTasks: false, homeDirectory: root, scanCategories: [.mailAttachments])
        state.categoryResults[.mailAttachments] = result
        state.scanState = .completed
        state.selectAllInCategory(.mailAttachments)
        state.setSelection(true, for: result.items)
        XCTAssertEqual(state.selectedCountInCategory(.mailAttachments), 0)
        state.toggleItem(try XCTUnwrap(result.items.first { $0.name == "Meeting.key" }))
        XCTAssertEqual(state.selectedCountInCategory(.mailAttachments), 1)
        XCTAssertTrue(state.scheduledCleanupCandidates.isEmpty)
        XCTAssertNil(state.cleanAll(scheduled: true))

        let cleanup = try XCTUnwrap(state.cleanAll())
        await cleanup.value
        XCTAssertFalse(files.fileExists(atPath: document.path))
        XCTAssertEqual(try Data(contentsOf: invoice), contents)
    }

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

    func testSavedReceiptIncludesEveryOutcomeAndPreservesPathBoundaries() {
        let kept = item("résumé", path: "/fixture/مجلد/résumé", size: 1200, date: nil)
        let moved = item("Build", path: "/fixture/Build", size: 4096, date: nil)
        let skipped = item("line\nbreak", path: "/fixture/line\nbreak", size: 3500, date: nil)
        let restored = item("Notes", path: "/fixture/Notes", size: 512, date: nil)
        let destination = "/fixture/Trash/Build 2"
        let formerDestination = "/fixture/Trash/Notes 2"
        let receipt = CleanupReceipt(rows: [
            .init(item: kept, disposition: .removed, bytes: 1200),
            .init(item: moved, disposition: .trashed, bytes: 4096, trashPath: destination),
            .init(item: skipped, disposition: .skipped, detail: "changed\u{2028}suffix\u{202e}"),
            .init(item: restored, disposition: .restored, bytes: 512, trashPath: formerDestination)
        ])

        let text = receipt.reportText
        XCTAssertTrue(text.contains(kept.path))
        XCTAssertTrue(text.contains(destination))
        XCTAssertTrue(text.contains(restored.path))
        XCTAssertFalse(text.contains(formerDestination))
        XCTAssertTrue(text.contains(skipped.path.debugDescription))
        XCTAssertFalse(text.contains(skipped.path))
        XCTAssertTrue(text.contains("changed\\u{2028}suffix\\u{202e}"))
        for row in receipt.rows {
            XCTAssertTrue(text.contains("[\(row.disposition.title)]"))
        }
    }

    @MainActor
    func testSupersededCategorySearchCannotReplaceCurrentRows() async throws {
        let browser = CategoryFilterState()
        let first = item("Cache 2", path: "/fixture/alpha/first", size: 10, date: nil)
        let second = item("Cache 12", path: "/fixture/beta/second", size: 20, date: nil)
        let resultID = UUID()
        let oldKey = CategoryFilterKey(resultID: resultID, filter: .init(query: "alpha", order: .name))
        let finalKey = CategoryFilterKey(resultID: resultID, filter: .init(query: "BETA", order: .name))

        let older = Task { @MainActor in await browser.update(oldKey, items: [first, second]) }
        for _ in 0..<100 where browser.requested != oldKey {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(browser.requested, oldKey)
        await browser.update(finalKey, items: [first, second])
        await older.value
        XCTAssertNil(browser.rows(for: oldKey))
        XCTAssertEqual(browser.rows(for: finalKey)?.items.map(\.id), [second.id])
        XCTAssertEqual(browser.rows(for: finalKey)?.ids, [second.id])

        let replacement = CategoryFilterKey(resultID: UUID(), filter: finalKey.filter)
        XCTAssertNil(browser.rows(for: replacement))
        await browser.update(replacement, items: [first])
        XCTAssertNil(browser.rows(for: finalKey))
        XCTAssertEqual(browser.rows(for: replacement)?.items.count, 0)
    }

    private func item(_ name: String, path: String = "/fixture", size: Int64, date: Date?) -> CleanableItem {
        CleanableItem(name: name, path: path, size: size, category: .largeFiles, isSelected: false, lastModified: date)
    }
}

final class CleanupPutBackTests: XCTestCase {
    private let files = FileManager.default
    private var root: URL!
    private var original: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("PureMac-Recovery-" + UUID().uuidString, isDirectory: true)
        original = root.appendingPathComponent("Projects/Build")
        trash = root.appendingPathComponent("Trash/Build 2")
        for url in [original!, trash!] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("original".utf8).write(to: original)
    }

    override func tearDownWithError() throws {
        if let root { try files.removeItem(at: root) }
    }

    private func move() throws -> TrackedTrashMove {
        let moved = try TrackedTrashMove.capture(from: original) { source in
            try files.moveItem(at: source, to: trash)
            return trash
        }
        return try XCTUnwrap(moved.recovery)
    }

    func testUsesActualTrashNameAndRetriesWithoutOverwriting() throws {
        let moved = try move()
        XCTAssertEqual(moved.verifiedTrashURL, trash)
        try Data("keep".utf8).write(to: original)
        XCTAssertThrowsError(try moved.putBack()) { error in
            XCTAssertEqual(error as? TrackedTrashMove.Failure, .occupied)
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: trash), Data("original".utf8))
        try files.removeItem(at: original)
        try files.createSymbolicLink(at: original, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try moved.putBack()) { error in
            XCTAssertEqual(error as? TrackedTrashMove.Failure, .occupied)
        }
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: original.path), root.appendingPathComponent("missing").path)
        try files.removeItem(at: original)
        try moved.putBack()
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertFalse(files.fileExists(atPath: trash.path))
        XCTAssertNil(moved.verifiedTrashURL)
        XCTAssertThrowsError(try moved.putBack())
    }

    func testMissingReplacedAndSymlinkedOriginalParentAreNeverCreatedOrFollowed() throws {
        let moved = try move()
        let destinationParent = original.deletingLastPathComponent()
        let parked = root.appendingPathComponent("parked")
        try files.moveItem(at: destinationParent, to: parked)
        XCTAssertThrowsError(try moved.putBack())
        XCTAssertFalse(files.fileExists(atPath: destinationParent.path))
        try files.createDirectory(at: destinationParent, withIntermediateDirectories: false)
        XCTAssertThrowsError(try moved.putBack())
        XCTAssertFalse(files.fileExists(atPath: original.path))
        try files.removeItem(at: destinationParent)
        try files.createSymbolicLink(at: destinationParent, withDestinationURL: parked)
        XCTAssertThrowsError(try moved.putBack())
        XCTAssertFalse(files.fileExists(atPath: parked.appendingPathComponent("Build").path))
        XCTAssertEqual(try Data(contentsOf: trash), Data("original".utf8))
    }

    func testRefusesReplacedTrashItemAndSymlinkedTrashParent() throws {
        let moved = try move()
        let parent = trash.deletingLastPathComponent()
        let parked = root.appendingPathComponent("parked")
        try files.moveItem(at: parent, to: parked)
        try files.createSymbolicLink(at: parent, withDestinationURL: parked)
        XCTAssertThrowsError(try moved.putBack())
        XCTAssertNil(moved.verifiedTrashURL)
        try files.removeItem(at: parent)
        try files.moveItem(at: parked, to: parent)
        try Data("replacement".utf8).write(to: trash, options: .atomic)
        XCTAssertThrowsError(try moved.putBack())
        XCTAssertNil(moved.verifiedTrashURL)
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: trash), Data("replacement".utf8))
    }

    func testWorkspaceRecoveryDoesNotRecreateMissingLockDirectory() async throws {
        let workspace = root.appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces/MyProject")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        original = workspace.appendingPathComponent("DerivedData")
        try files.createDirectory(at: original, withIntermediateDirectories: false)
        let moved = try move()
        let engine = CleaningEngine(homeDirectory: root)
        do {
            try await engine.putBack(moved)
            XCTFail("A workspace with no lock parent must not be restored")
        } catch {
            XCTAssertEqual(error as? TrackedTrashMove.Failure, .workspaceBusy)
        }
        XCTAssertFalse(files.fileExists(atPath: workspace.appendingPathComponent("locks").path))
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertEqual(moved.verifiedTrashURL, trash)
    }

    @MainActor
    func testReceiptRestoresTrackedDirectoryAfterConflictWithoutDoubleCredit() async throws {
        let data = root.appendingPathComponent("Library/Developer/XcodeBuildMCP/DerivedData")
        let marker = data.appendingPathComponent("fixture")
        try files.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("restore me".utf8).write(to: marker)
        let item = CleanableItem(name: "Fixture", path: data.resolvingSymlinksInPath().path, size: 4096,
                                 category: .xcodeJunk, isSelected: true, lastModified: nil)
        let state = AppState(performStartupTasks: false, homeDirectory: root, scanCategories: [.xcodeJunk])
        state.categoryResults[.xcodeJunk] = CategoryResult(category: .xcodeJunk, items: [item], totalSize: item.size)
        state.scanState = .completed
        let cleanup = try XCTUnwrap(state.cleanReviewed(CleanupSelection(items: [item])))
        await cleanup.value
        let receipt = try XCTUnwrap(state.lastCleanupReceipt)
        let row = try XCTUnwrap(receipt.rows.first)
        let recovery = try XCTUnwrap(row.recovery)
        defer { if let url = recovery.verifiedTrashURL { try? files.removeItem(at: url) } }
        XCTAssertEqual(row.disposition, .trashed)
        try Data("new file".utf8).write(to: data)
        XCTAssertNil(state.putBackCleanupItem(row.id, receiptID: UUID()))
        let conflict = try XCTUnwrap(state.putBackCleanupItem(row.id, receiptID: receipt.id))
        XCTAssertNil(state.putBackCleanupItem(row.id, receiptID: receipt.id))
        XCTAssertFalse(state.canRemoveDeviceBackups)
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        await conflict.value
        XCTAssertEqual(try Data(contentsOf: data), Data("new file".utf8))
        XCTAssertEqual(state.lastCleanupReceipt?.rows.first?.detail, TrackedTrashMove.Failure.occupied.localizedDescription)
        try files.removeItem(at: data)
        let retry = try XCTUnwrap(state.putBackCleanupItem(row.id, receiptID: receipt.id))
        await retry.value
        XCTAssertEqual(try Data(contentsOf: marker), Data("restore me".utf8))
        XCTAssertEqual(state.lastCleanupReceipt?.rows.first?.disposition, .restored)
        XCTAssertNil(state.lastCleanupReceipt?.rows.first?.detail)
        XCTAssertEqual(state.lastCleanupReceipt?.trashedBytes, 4096)
        XCTAssertEqual(state.lastCleanupReceipt?.removedBytes, 0)
        XCTAssertNil(state.putBackCleanupItem(row.id, receiptID: receipt.id))
        XCTAssertNil(recovery.verifiedTrashURL)
    }

    func testAmbiguousCopyOrMissingReturnedLocationOffersNoRecovery() throws {
        let copied = try TrackedTrashMove.capture(from: original) { source in
            try files.copyItem(at: source, to: trash)
            return trash
        }
        XCTAssertEqual(copied.trashURL, trash)
        XCTAssertNil(copied.recovery)
        let missing = try TrackedTrashMove.capture(from: original) { source in
            try files.removeItem(at: source)
            return nil
        }
        XCTAssertNil(missing.trashURL)
        XCTAssertNil(missing.recovery)
    }
}

final class DashboardResultIndexTests: XCTestCase {
    func testReturningToSameScanKeepsWindowFiltersAndNewScanClearsThem() {
        let filters = DashboardResultsFilters()
        let scanDate = Date(timeIntervalSince1970: 1_000)
        filters.synchronize(scanDate: scanDate)
        filters.query = "archive"
        filters.categoryScope = .mailAttachments
        filters.selectedOnly = true
        filters.synchronize(scanDate: scanDate)
        XCTAssertEqual(filters.query, "archive")
        XCTAssertEqual(filters.categoryScope, .mailAttachments)
        XCTAssertTrue(filters.selectedOnly)
        filters.synchronize(scanDate: scanDate.addingTimeInterval(1))
        XCTAssertEqual(filters.query, "")
        XCTAssertNil(filters.categoryScope)
        XCTAssertFalse(filters.selectedOnly)
    }

    func testScopedPathLookupKeepsHiddenSelectionsForReview() async throws {
        let log = CleanableItem(name: "Server log", path: "/fixture/Résumé/cache", size: 1200, category: .aiApps, isSelected: true, lastModified: nil)
        let history = CleanableItem(name: "Résumé history", path: "/fixture/history", size: 1600, category: .aiApps, isSelected: false, lastModified: nil)
        let preview = CleanableItem(name: "Résumé preview", path: "/fixture/mail", size: 2000, category: .mailAttachments, isSelected: true, lastModified: nil)
        let categories = [
            CategoryResult(category: .aiApps, items: [log, history], totalSize: 2800),
            CategoryResult(category: .mailAttachments, items: [preview], totalSize: 2000)
        ]
        let index = DashboardResultIndex()
        let key = DashboardSearchKey(categories: categories.map(\.id), scope: .aiApps, text: "RESUME")
        let lookup = await index.match(key: key, categories: categories)
        let matches = try XCTUnwrap(lookup)
        XCTAssertEqual(matches.items.map(\.id), [history.id, log.id])
        let view = DashboardReviewRows(categories: categories, matches: matches, selectedOnly: true, isSelected: { $0.isSelected })
        XCTAssertEqual(view.visible.map(\.id), [log.id])
        XCTAssertEqual(view.selectedIDs, [log.id, preview.id])
        XCTAssertEqual(view.hiddenSelected, 1)
        XCTAssertEqual(view.selectedBytes, 3200)
        XCTAssertEqual(view.totalCount, 3)
    }

    func testFreshScanReplacesRankingAndRetainsZeroByteManagedAction() async throws {
        let index = DashboardResultIndex()
        let old = CleanableItem(name: "Old cache", path: "/fixture/cache", size: 42, category: .dockerCache, isSelected: true, lastModified: nil)
        let action = CleanableItem(name: "Prune images", path: "", size: 0, category: .dockerCache, isSelected: false, lastModified: nil)
        for item in [old, action] {
            let category = CategoryResult(category: item.category, items: [item], totalSize: item.size)
            let key = DashboardSearchKey(categories: [category.id], scope: nil, text: "")
            let lookup = await index.match(key: key, categories: [category])
            XCTAssertEqual(try XCTUnwrap(lookup).items.map(\.id), [item.id])
        }
    }
}
