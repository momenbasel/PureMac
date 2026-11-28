import AppKit
import Combine
import XCTest
@testable import PureMac

@MainActor
final class AppStateTests: XCTestCase {
    func testScanForAppFilesTracksLocationsWhileResultsArePending() throws {
        var completion: ((Set<URL>) -> Void)?
        let expectedLocations = ["/one", "/two", "/three"]
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: {
                StubLocations(paths: expectedLocations)
            },
            appFileScanner: { _, locations, pendingCompletion in
                XCTAssertEqual(locations.appSearch.paths, expectedLocations)
                completion = pendingCompletion
            }
        )

        appState.scanForAppFiles(makeApp())

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, expectedLocations.count)

        let pendingCompletion = try XCTUnwrap(completion)
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/B"),
            URL(fileURLWithPath: "/tmp/A")
        ]

        pendingCompletion(urls)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(
            appState.discoveredFiles,
            urls.sorted { $0.path < $1.path }
        )
        XCTAssertTrue(appState.selectedFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, urls.count)
    }

    func testOlderAppScanCannotReplaceNewerAppResults() {
        var completions: [((Set<URL>) -> Void)] = []
        let state = AppState(performStartupTasks: false, appFileScanner: { _, _, completion in
            completions.append(completion)
        })
        state.scanForAppFiles(makeApp())
        state.scanForAppFiles(makeApp())
        let latest: Set<URL> = [URL(fileURLWithPath: "/fixtures/latest")]
        completions[1](latest)
        completions[0]([URL(fileURLWithPath: "/fixtures/stale")])
        XCTAssertEqual(Set(state.discoveredFiles), latest)
        XCTAssertTrue(state.selectedFiles.isEmpty)
    }

    func testFullDiskAccessRetryKeepsUninstallInTrashFlow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original")
        let destination = folder.appendingPathComponent("test-trash")
        try Data([1]).write(to: original)
        let state = AppState(performStartupTasks: false, appFileTrasher: { url in
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        var file = AppRemovalFile(original)
        file.outcome = .needsAccess
        let receipt = AppRemovalReview(source: .app("Fixture"), files: [file], stage: .receipt)
        await state.retryReviewedAppFileAccess(receipt)
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .trashed)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1]))
    }

    func testAppReceiptUsesReturnedTrashNameAndPutsBackOnlyAfterConflictClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let trash = root.appendingPathComponent("Test Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("session")
        let returned = trash.appendingPathComponent("session 2")
        try Data([42]).write(to: original)
        let state = AppState(performStartupTasks: false, homeDirectory: root,
                             appFileScanner: { _, _, complete in complete([original]) },
                             appFileTrasher: { url in
            try FileManager.default.moveItem(at: url, to: returned)
            return returned
        })
        state.selectedApp = makeApp()
        state.discoveredFiles = [original]
        state.reviewSelectedAppFiles([original])
        await state.performAppRemovalReview()

        let receipt = try XCTUnwrap(state.appRemovalReview)
        let row = try XCTUnwrap(receipt.files.first)
        XCTAssertEqual(row.outcome, .trashed)
        XCTAssertEqual(row.trashDestination, returned)
        XCTAssertEqual(row.recovery?.verifiedTrashURL, returned)
        await state.putBackAppFile(reviewID: UUID(), url: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        try Data([7]).write(to: original)
        await state.putBackAppFile(reviewID: receipt.id, url: original)
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .trashed)
        XCTAssertNotNil(state.appRemovalReview?.files.first?.recoveryError)
        XCTAssertEqual(try Data(contentsOf: original), Data([7]))
        XCTAssertEqual(try Data(contentsOf: returned), Data([42]))

        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("other-session"))
        await state.putBackAppFile(reviewID: receipt.id, url: original)
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .restored)
        XCTAssertNil(state.appRemovalReview?.files.first?.recoveryError)
        XCTAssertNil(state.appRemovalReview?.files.first?.recovery)
        XCTAssertEqual(try Data(contentsOf: original), Data([42]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: returned.path))
    }

    func testReplacedTrashObjectDisablesAppRecoveryAndPreservesReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("session")
        let returned = root.appendingPathComponent("trashed-session")
        let parked = root.appendingPathComponent("parked-session")
        try Data([1]).write(to: original)
        let state = AppState(performStartupTasks: false, homeDirectory: root, appFileTrasher: { url in
            try FileManager.default.moveItem(at: url, to: returned)
            return returned
        })
        state.selectedApp = makeApp()
        state.discoveredFiles = [original]
        state.reviewSelectedAppFiles([original])
        await state.performAppRemovalReview()
        let receipt = try XCTUnwrap(state.appRemovalReview)
        XCTAssertNotNil(receipt.files.first?.recovery)
        try FileManager.default.moveItem(at: returned, to: parked)
        try Data([2]).write(to: returned)
        await state.putBackAppFile(reviewID: receipt.id, url: original)
        XCTAssertNil(state.appRemovalReview?.files.first?.recovery)
        XCTAssertNotNil(state.appRemovalReview?.files.first?.recoveryError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: returned), Data([2]))
        XCTAssertEqual(try Data(contentsOf: parked), Data([1]))
    }

    func testMissingTrashProofDoesNotOfferOrExecutePutBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("session")
        let moved = root.appendingPathComponent("actual-destination")
        try Data([3]).write(to: original)
        let state = AppState(performStartupTasks: false, homeDirectory: root, appFileTrasher: { url in
            try FileManager.default.moveItem(at: url, to: moved)
            return nil
        })
        state.selectedApp = makeApp()
        state.discoveredFiles = [original]
        state.reviewSelectedAppFiles([original])
        await state.performAppRemovalReview()
        let receipt = try XCTUnwrap(state.appRemovalReview)
        XCTAssertEqual(receipt.files.first?.outcome, .trashed)
        XCTAssertNil(receipt.files.first?.trashDestination)
        XCTAssertNil(receipt.files.first?.recovery)
        await state.putBackAppFile(reviewID: receipt.id, url: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: moved), Data([3]))
    }

    func testUninstallDefaultsKeepApplicationDataAndPreferences() {
        let app = makeApp()
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.fixture")
        let data = URL(fileURLWithPath: "/Users/fixture/Library/Application Support/Fixture")
        let settings = URL(fileURLWithPath: "/Users/fixture/Library/Preferences/com.fixture.plist")
        let state = AppState(performStartupTasks: false, appFileScanner: { _, _, complete in
            complete([app.path, cache, data, settings])
        })
        state.scanForAppFiles(app)
        XCTAssertEqual(state.selectedFiles, [app.path, cache])
        XCTAssertEqual(Set(state.discoveredFiles), [app.path, cache, data, settings])
    }

    func testCancellationAndReplacementPreserveTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Original")
        let renamed = folder.appendingPathComponent("Renamed")
        try Data([1]).write(to: original)
        let state = AppState(performStartupTasks: false, appFileTrasher: { _ in
            XCTFail("Unexpected Trash operation")
            return nil
        })
        state.selectedApp = makeApp()
        state.discoveredFiles = [original]
        state.reviewSelectedAppFiles([original])
        XCTAssertEqual(state.appRemovalReview?.visibleFiles.map(\.url), [original])
        state.closeAppRemovalReview()
        XCTAssertNil(state.appRemovalReview)
        XCTAssertEqual(try Data(contentsOf: original), Data([1]))
        state.reviewSelectedAppFiles([original])
        state.selectedFiles.removeAll()
        try FileManager.default.moveItem(at: original, to: renamed)
        try Data([2]).write(to: original)
        await state.performAppRemovalReview()
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .changed)
        XCTAssertEqual(try Data(contentsOf: original), Data([2]))
    }

    func testDecliningPermanentReviewLeavesProtectedFileInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = apps.appendingPathComponent("Fixture.app")
        try Data([42]).write(to: file)
        let state = AppState(performStartupTasks: false, homeDirectory: root, appFileTrasher: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        state.selectedApp = makeApp()
        state.discoveredFiles = [file]
        state.reviewSelectedAppFiles([file])
        await state.performAppRemovalReview()
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .needsAdmin)
        state.reviewProtectedAppFiles()
        XCTAssertEqual(state.appRemovalReview?.stage, .permanent)
        XCTAssertEqual(state.appRemovalReview?.visibleFiles.map(\.url), [file])
        state.closeAppRemovalReview()
        XCTAssertEqual(state.appRemovalReview?.stage, .receipt)
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .needsAdmin)
        XCTAssertEqual(try Data(contentsOf: file), Data([42]))
    }

    func testAdministratorCommandRechecksExactFileIdentityWithoutElevation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("quoted ' path\nfixture")
        let previous = folder.appendingPathComponent("original")
        try Data([1]).write(to: target)
        let identity = try XCTUnwrap(AppRemovalFile(target).identity.adminKey)
        try FileManager.default.moveItem(at: target, to: previous)
        try Data([2]).write(to: target)

        func run(_ key: String) throws -> String {
            let command = Process()
            let output = Pipe()
            command.executableURL = URL(fileURLWithPath: "/bin/sh")
            command.arguments = ["-c", CleaningEngine.reviewedRemovalFunction + "\nremove_reviewed 0 \"$1\" \"$2\"",
                                 "fixture", target.path, key]
            command.standardOutput = output
            try command.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0)
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        XCTAssertEqual(try run(identity), "0 changed")
        XCTAssertEqual(try Data(contentsOf: target), Data([2]))
        let replacement = try XCTUnwrap(AppRemovalFile(target).identity.adminKey)
        XCTAssertEqual(try run(replacement), "0 deleted")
        XCTAssertEqual(try run(replacement), "0 missing")
        XCTAssertEqual(try Data(contentsOf: previous), Data([1]))
    }

    func testLeftoverReviewBlocksItemsOutsideAllowedRoots() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([42]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = AppState(performStartupTasks: false, appFileTrasher: { _ in
            XCTFail("Unexpected Trash operation")
            return nil
        })
        state.orphanedFiles = [file]
        state.reviewSelectedLeftovers([file])
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .blocked)
        await state.performAppRemovalReview()
        XCTAssertEqual(state.appRemovalReview?.files.first?.outcome, .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testVisibleSelectionPreservesHiddenRowsAndManualDefaults() {
        let state = AppState(performStartupTasks: false)
        let visible = cleanupItem(selected: false)
        let hidden = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [visible, hidden], totalSize: 200)
        state.setSelection(true, for: [visible])
        XCTAssertTrue(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
        state.setSelection(false, for: [visible])
        XCTAssertFalse(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
    }

    func testBulkSelectionPublishesOncePerChangedOverrideSet() {
        let state = AppState(performStartupTasks: false)
        let rows = (0..<1_000).map { _ in cleanupItem(selected: false) }
        var handOnly = cleanupItem(selected: false)
        handOnly.selectOnlyByHand = true
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        state.setSelection(true, for: rows + [handOnly])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(state.selectedCleanupItems, Set(rows.map(\.id)))
        XCTAssertFalse(state.isItemSelected(handOnly))
        state.setSelection(true, for: rows)
        XCTAssertEqual(changes, 1)
        state.setSelection(false, for: rows)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(state.selectedCleanupItems.isEmpty)
    }

    func testScheduledScanPreservesPendingReviewInBackground() async {
        let state = AppState(performStartupTasks: false)
        let item = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: 100)
        state.scanState = .completed
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: true))
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        let outcome = await state.runScheduledScan()
        XCTAssertEqual(outcome, .deferred)
        state.showCleanConfirmation = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [item.id])
        XCTAssertEqual(state.scanState, .completed)
    }

    func testScheduleRearmsRestoresAndDisablesImmediately() throws {
        let suite = "PureMacTests.Schedule." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulerService(defaults: defaults, now: { now })
        defer { scheduler.stop() }

        scheduler.toggleEnabled(true)
        XCTAssertEqual(scheduler.config.nextRunDate, now.addingTimeInterval(ScheduleInterval.daily.seconds))
        scheduler.updateSchedule(interval: .hours1)
        let hourlyDeadline = now.addingTimeInterval(3600)
        XCTAssertEqual(scheduler.config.nextRunDate, hourlyDeadline)

        now = now.addingTimeInterval(600)
        let restored = SchedulerService(defaults: defaults, now: { now })
        restored.start()
        XCTAssertTrue(restored.config.isEnabled)
        XCTAssertEqual(restored.config.nextRunDate, hourlyDeadline)
        restored.toggleEnabled(false)
        XCTAssertNil(restored.config.nextRunDate)
        XCTAssertFalse(SchedulerService(defaults: defaults, now: { now }).config.isEnabled)
    }

    func testScheduleDefersRetriesAndRecordsOnlyCompletedWork() async throws {
        let suite = "PureMacTests.Schedule." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulerService(defaults: defaults, now: { now })
        defer { scheduler.stop() }
        scheduler.toggleEnabled(true)
        now = try XCTUnwrap(scheduler.config.nextRunDate)
        var calls = 0
        scheduler.setTrigger { [weak scheduler] in
            calls += 1
            await scheduler?.checkAndRun()
            return calls == 1 ? .deferred : .completed
        }
        await scheduler.checkAndRun()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(scheduler.isDeferred)
        XCTAssertNil(scheduler.config.lastRunDate)
        XCTAssertEqual(scheduler.config.nextRunDate, now)

        now = now.addingTimeInterval(60)
        await scheduler.checkAndRun()
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(scheduler.isDeferred)
        XCTAssertEqual(scheduler.config.lastRunDate, now)
        XCTAssertEqual(scheduler.config.nextRunDate, now.addingTimeInterval(ScheduleInterval.daily.seconds))
        await scheduler.checkAndRun()
        XCTAssertEqual(calls, 2)
    }

    func testOverdueScheduleAndUnconfirmedAutoCleanDoNotRunAtLaunch() throws {
        let suite = "PureMacTests.Schedule." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var old = ScheduleConfig()
        old.isEnabled = true
        old.autoClean = true
        old.lastRunDate = now.addingTimeInterval(-172800)
        old.nextRunDate = now.addingTimeInterval(-86400)
        defaults.set(try JSONEncoder().encode(old), forKey: "PureMac.ScheduleConfig")

        let unconfirmed = SchedulerService(defaults: defaults, now: { now })
        unconfirmed.start()
        XCTAssertFalse(unconfirmed.config.isEnabled)
        XCTAssertFalse(unconfirmed.config.autoClean)
        XCTAssertNil(unconfirmed.config.nextRunDate)

        defaults.set(true, forKey: "PureMac.OnboardingComplete")
        let migrated = SchedulerService(defaults: defaults, now: { now })
        migrated.start()
        defer { migrated.stop() }
        XCTAssertTrue(migrated.config.isEnabled)
        XCTAssertTrue(migrated.config.autoClean)
        XCTAssertEqual(migrated.config.lastRunDate, old.lastRunDate)
        XCTAssertEqual(migrated.config.nextRunDate, now.addingTimeInterval(ScheduleInterval.daily.seconds))
    }

    func testScheduledCleanupExcludesTrashAndHandSelectedRowsFromThreshold() throws {
        let suite = "PureMacTests.Schedule." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(performStartupTasks: false, scheduler: SchedulerService(defaults: defaults))
        let eligible = cleanupItem(selected: true)
        var manual = cleanupItem(selected: false)
        manual.selectOnlyByHand = true
        let trash = CleanableItem(name: "Trash fixture", path: "/fixtures/trash", size: 800_000_000,
                                  category: .trashBins, isSelected: true, lastModified: nil)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [eligible, manual], totalSize: 200)
        state.categoryResults[.trashBins] = CategoryResult(category: .trashBins, items: [trash], totalSize: trash.size)
        state.toggleItem(manual)
        XCTAssertEqual(state.scheduledCleanupCandidates.map(\.id), [eligible.id])
        XCTAssertEqual(state.scheduledCleanupCandidates.reduce(0) { $0 + $1.size }, eligible.size)
        XCTAssertTrue(state.isItemSelected(trash))
        XCTAssertNil(state.cleanAll(scheduled: true))
        XCTAssertNil(state.cleanAll(itemIDs: [trash.id, manual.id], scheduled: true))
        XCTAssertEqual(state.totalItemCount, 3)
    }

    func testScheduledCompletionWaitsForFixtureCleanupAndKeepsTrash() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let cache = fixture.appendingPathComponent("Library/Caches/disposable.bin")
        let trash = fixture.appendingPathComponent(".Trash/keep.bin")
        defer { try? manager.removeItem(at: fixture) }
        for file in [cache, trash] {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8_192).write(to: file)
        }

        let suite = "PureMacTests.Schedule." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulerService(defaults: defaults, now: { now })
        defer { scheduler.stop() }
        let state = AppState(performStartupTasks: false, scheduler: scheduler, homeDirectory: fixture,
                             scanCategories: [.userCache, .trashBins])
        scheduler.setTrigger { [weak state] in await state?.runScheduledScan() ?? .cancelled }
        scheduler.toggleEnabled(true)
        scheduler.config.minimumCleanSize = 1
        scheduler.config.notifyOnCompletion = false
        scheduler.config.autoClean = true
        now = try XCTUnwrap(scheduler.config.nextRunDate)
        await scheduler.checkAndRun()

        XCTAssertEqual(scheduler.config.lastRunDate, now)
        XCTAssertFalse(manager.fileExists(atPath: cache.path))
        XCTAssertTrue(manager.fileExists(atPath: trash.path))
        XCTAssertEqual(state.lastCleanupReceipt?.rows.map(\.item.path), [cache.path])
        XCTAssertEqual(state.categoryResults[.trashBins]?.items.map(\.path), [trash.path])
    }

    func testManagedDerivedDataRequiresManualSelectionEvenForScheduledCleanup() throws {
        let state = AppState(performStartupTasks: false)
        let managedRoot = try XCTUnwrap(XcodeBuildMCPDerivedDataSupport.managedRoots().first)
        let item = CleanableItem(
            name: "XcodeBuildMCP: Fixture",
            path: managedRoot
                .appendingPathComponent("workspaces/Fixture-\(UUID().uuidString)/DerivedData").path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: false,
            lastModified: .distantPast
        )
        state.categoryResults[.xcodeJunk] = CategoryResult(category: .xcodeJunk, items: [item], totalSize: item.size)
        state.scanState = .completed

        XCTAssertFalse(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, 0)
        state.cleanAll()
        XCTAssertEqual(state.scanState, .completed)
        state.cleanAll(scheduled: true)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.categoryResults[.xcodeJunk]?.items.map(\.id), [item.id])

        state.toggleItem(item)
        XCTAssertTrue(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, item.size)
        state.toggleItem(item)
        XCTAssertFalse(state.isItemSelected(item))
    }

    func testScheduledScanWaitsForActiveOperations() {
        let state = AppState(performStartupTasks: false)
        state.scanState = .cleaning(progress: 0.2)
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.scanState = .idle
        state.isRemovingAppFiles = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
    }

    func testStopScanPreservesCompletedResultsAndDoesNotStopCleaning() {
        let state = AppState(performStartupTasks: false)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [cleanupItem(selected: true)], totalSize: 100)
        state.scanState = .scanning(progress: 0.5, currentCategory: "User Cache")
        state.cancelScan()
        XCTAssertTrue(state.scanWasCancelled)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.totalItemCount, 1)
        state.scanState = .cleaning(progress: 0.5)
        state.cancelScan()
        XCTAssertEqual(state.scanState, .cleaning(progress: 0.5))
    }

    func testChangedResultRequiresFreshScanBeforeReviewOrRemoval() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let file = fixture.appendingPathComponent("Library/Caches/Changed.bin")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        try Data(repeating: 1, count: 4096).write(to: file)
        let state = AppState(performStartupTasks: false, homeDirectory: fixture, scanCategories: [.userCache])
        let item = CleanableItem(name: file.lastPathComponent, path: file.path, size: 4096, category: .userCache,
                                 isSelected: true, lastModified: nil)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: item.size)
        state.scanState = .completed
        let review = CleanupSelection(items: [item])
        let replacement = Data(repeating: 2, count: 8192)
        try replacement.write(to: file, options: .atomic)

        let first = try XCTUnwrap(state.cleanReviewed(review))
        await first.value
        XCTAssertEqual(state.lastCleanupReceipt?.rows.first?.disposition, .skipped)
        XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [item.id])
        XCTAssertFalse(state.isCleanupItemAvailable(item))
        state.toggleItem(item)
        state.selectAllInCategory(.userCache)
        state.setSelection(true, for: [item])
        XCTAssertFalse(state.isItemSelected(item))
        XCTAssertNil(state.cleanReviewed(CleanupSelection(items: [item])))
        XCTAssertNil(state.cleanAll(itemIDs: [item.id]))
        XCTAssertEqual(try Data(contentsOf: file), replacement)

        state.scanSingleCategory(.userCache)
        let finished = expectation(description: "fresh category scan")
        let subscription = state.$scanState.sink { if $0 == .completed { finished.fulfill() } }
        await fulfillment(of: [finished], timeout: 10)
        subscription.cancel()
        let refreshed = try XCTUnwrap(state.categoryResults[.userCache]?.items.first { $0.path == file.path })
        XCTAssertNotEqual(item.id, refreshed.id)
        XCTAssertTrue(state.isCleanupItemAvailable(refreshed))
        XCTAssertTrue(state.isItemSelected(refreshed))
        let second = try XCTUnwrap(state.cleanReviewed(CleanupSelection(items: [refreshed])))
        await second.value
        XCTAssertEqual(state.lastCleanupReceipt?.rows.first?.disposition, .removed)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    private func cleanupItem(selected: Bool) -> CleanableItem {
        CleanableItem(name: "Fixture", path: "/fixtures/\(UUID().uuidString)", size: 100, category: .userCache, isSelected: selected, lastModified: nil)
    }

    private func makeApp() -> InstalledApp {
        InstalledApp(
            id: UUID(),
            appName: "PureMac",
            bundleIdentifier: "com.puremac.app",
            path: URL(fileURLWithPath: "/Applications/PureMac.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
    }
}

private final class StubLocations: Locations {
    init(paths: [String]) {
        super.init()
        appSearch = SearchCategory(name: "Apps", paths: paths)
    }
}
