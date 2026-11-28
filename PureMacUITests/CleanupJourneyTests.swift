import XCTest

@MainActor
final class CleanupJourneyTests: XCTestCase {
    func testReviewCancelAndCleanOnlyReviewedFiles() throws {
        let run = UUID()
        let root = try makeFixture(for: run)
        let files = FileManager.default
        let cache = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let http = root.appendingPathComponent("Library/HTTPStorages", isDirectory: true)
        let reviewed = http.appendingPathComponent("Reviewed.bin")
        let vanished = cache.appendingPathComponent("Vanished.bin")
        let changed = cache.appendingPathComponent("Changed.bin")
        let unselected = http.appendingPathComponent("Keep my session.bin")
        let outsideScan = root.appendingPathComponent("Unscanned.bin")
        let untouched = Data(repeating: 0xA3, count: 8_192)
        try Data(repeating: 0x17, count: 16_384).write(to: reviewed)
        try Data(repeating: 0x42, count: 32_768).write(to: vanished)
        try Data(repeating: 0x53, count: 4_096).write(to: changed)
        try untouched.write(to: unselected)
        try untouched.write(to: outsideScan)

        let app = launchFixture(run, animationsEnabled: false)
        defer { app.terminate() }

        let elements = app.descendants(matching: .any)
        let settings = elements["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.click()
        let toggle = elements["settings.animateInterface"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toggle.value as? String == "0" || (toggle.value as? NSNumber)?.boolValue == false)
        elements["sidebar.cleaning.Smart Scan"].firstMatch.click()

        let scan = app.buttons["dashboard.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10), app.debugDescription)
        scan.click()
        let review = app.buttons["dashboard.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        let reviewedToggle = app.checkBoxes.matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@",
                                                                 reviewed.lastPathComponent, reviewed.lastPathComponent)).firstMatch
        XCTAssertTrue(reviewedToggle.waitForExistence(timeout: 5), app.debugDescription)
        reviewedToggle.click()
        review.click()
        let cancel = app.buttons["cleanup.review.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.click()
        XCTAssertTrue(files.fileExists(atPath: reviewed.path))
        XCTAssertTrue(files.fileExists(atPath: vanished.path))
        XCTAssertTrue(files.fileExists(atPath: changed.path))

        review.click()
        let confirm = app.buttons["cleanup.review.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        let displayed = app.descendants(matching: .any)
        XCTAssertTrue(confirm.title.contains("3") || confirm.label.contains("3"))
        for file in [reviewed, vanished, changed] {
            let suffix = "\(root.lastPathComponent)/Library/\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent)"
            let row = displayed.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                    suffix, suffix)).firstMatch
            XCTAssertTrue(row.exists, "The confirmation must identify the fixture file \(file.lastPathComponent)")
        }
        attachWindow(app, name: "Review selected files")
        try files.removeItem(at: vanished)
        let replacement = Data(repeating: 0x91, count: 6_144)
        try replacement.write(to: changed, options: .atomic)
        confirm.click()

        let remaining = app.buttons["dashboard.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10), app.debugDescription)
        let receipt = app.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label }
        let outcomes = [reviewed.lastPathComponent: "Removed", vanished.lastPathComponent: "Already gone",
                        changed.lastPathComponent: "Skipped"]
        for (name, status) in outcomes {
            let start = try XCTUnwrap(receipt.firstIndex(of: name), app.debugDescription)
            let row = receipt.dropFirst(start + 1).prefix { outcomes[$0] == nil }
            XCTAssertTrue(row.contains(status), "Missing \(status) outcome for \(name)")
        }
        let expectedBytes = ByteCountFormatter.string(fromByteCount: 16_384, countStyle: .file)
        let metric = try XCTUnwrap(receipt.firstIndex(of: "Estimated removed"), app.debugDescription)
        XCTAssertEqual(receipt.dropFirst(metric + 1).first, expectedBytes)
        XCTAssertFalse(files.fileExists(atPath: reviewed.path))
        XCTAssertEqual(try Data(contentsOf: changed), replacement)
        XCTAssertEqual(try Data(contentsOf: unselected), untouched)
        XCTAssertEqual(try Data(contentsOf: outsideScan), untouched)
        attachWindow(app, name: "Cleanup receipt")
        remaining.click()
        XCTAssertTrue(app.buttons["dashboard.rescan"].waitForExistence(timeout: 5), app.debugDescription)
        let selection = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                             "0 of 2 selected", "0 of 2 selected")).firstMatch
        XCTAssertTrue(selection.exists, app.debugDescription)
        XCTAssertFalse(review.isEnabled)
    }

    func testPutBackRestoresTheFileFromItsReceipt() throws {
        let run = UUID()
        let root = try makeFixture(for: run)
        let session = root.appendingPathComponent("Library/HTTPStorages/Recovery-\(run.uuidString).session")
        let moved = root.appendingPathComponent("Trashed-\(run.uuidString).session")
        let original = Data("Synthetic app recovery fixture".utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fixture.app"), withIntermediateDirectories: false)
        try original.write(to: session)
        let app = launchFixture(run, recoverAppFile: true)
        defer { app.terminate() }
        let controls = app.descendants(matching: .any)
        let apps = controls["sidebar.uninstaller"].firstMatch
        XCTAssertTrue(apps.waitForExistence(timeout: 10))
        apps.click()
        let review = app.buttons["apps.fileReview.\(session.lastPathComponent)"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.click()
        let move = app.buttons["appRemoval.confirm"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.click()
        let putBack = app.buttons["appRemoval.putBack.\(session.lastPathComponent)"]
        XCTAssertTrue(putBack.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["appRemoval.reveal.\(session.lastPathComponent)"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try Data(contentsOf: moved), original)
        attachWindow(app, name: "App file recovery")
        putBack.click()
        let restored = controls["appRemoval.restored.\(session.lastPathComponent)"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(putBack.exists)
        XCTAssertEqual(try Data(contentsOf: session), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }

    func testCancelToolbarAndSingleFileRemoval() throws {
        let run = UUID()
        let root = try makeFixture(for: run)
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let appFile = bundle.appendingPathComponent("fixture.bin")
        let session = root.appendingPathComponent("Library/HTTPStorages/Fixture.session")
        let original = Data("Fixture contents".utf8)
        try original.write(to: appFile)
        try original.write(to: session)

        let app = launchFixture(run)
        defer { app.terminate() }
        let elements = app.descendants(matching: .any)
        let uninstaller = elements["sidebar.uninstaller"].firstMatch
        XCTAssertTrue(uninstaller.waitForExistence(timeout: 10), app.debugDescription)
        uninstaller.click()
        let bundleID = "test.puremac.fixture"
        let fixtureDetails = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", bundleID, bundleID)).firstMatch
        XCTAssertTrue(fixtureDetails.waitForExistence(timeout: 5), app.debugDescription)
        let toolbar = app.buttons["apps.reviewRemoval"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), app.debugDescription)
        toolbar.click()
        let bundlePath = elements["appRemoval.path.Fixture.app"].firstMatch
        let sessionPath = elements["appRemoval.path.Fixture.session"].firstMatch
        XCTAssertTrue(bundlePath.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue([bundlePath.label, bundlePath.value as? String ?? ""].contains { $0.contains(root.lastPathComponent) })
        XCTAssertFalse(sessionPath.exists)
        let cancel = app.buttons["appRemoval.cancel"]
        cancel.click()
        XCTAssertEqual(try Data(contentsOf: appFile), original)
        XCTAssertEqual(try Data(contentsOf: session), original)

        let individual = app.buttons["apps.fileReview.Fixture.session"]
        XCTAssertTrue(individual.waitForExistence(timeout: 5), app.debugDescription)
        individual.click()
        XCTAssertTrue(sessionPath.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue([sessionPath.label, sessionPath.value as? String ?? ""].contains { $0.contains(root.lastPathComponent) })
        XCTAssertFalse(bundlePath.exists)
        attachWindow(app, name: "Review one app file")
        cancel.click()
        XCTAssertTrue(toolbar.isEnabled)
        XCTAssertEqual(try Data(contentsOf: appFile), original)
        XCTAssertEqual(try Data(contentsOf: session), original)
    }

    func testReviewIncludesSelectedItemsHiddenBySearchAndFilters() throws {
        let run = UUID()
        let root = try makeFixture(for: run)
        let cache = root.appendingPathComponent("Library/Caches")
        let aiCache = cache.appendingPathComponent("ollama", isDirectory: true)
        try FileManager.default.createDirectory(at: aiCache, withIntermediateDirectories: false)
        let match = cache.appendingPathComponent("Résumé build.log")
        let hidden = cache.appendingPathComponent("Render.log")
        let aiFile = aiCache.appendingPathComponent("fixture.log")
        let unchecked = root.appendingPathComponent("Library/HTTPStorages/Résumé session.data")
        let original = Data(repeating: 0x22, count: 8_192)
        for file in [match, hidden, aiFile, unchecked] { try original.write(to: file) }
        let largerUnselected = Data(repeating: 0x31, count: 32_768)
        for number in 1...21 {
            let file = unchecked.deletingLastPathComponent().appendingPathComponent("Other session \(number).data")
            try largerUnselected.write(to: file)
        }
        let app = launchFixture(run, animationsEnabled: false)
        defer { app.terminate() }
        let scan = app.buttons["dashboard.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10), app.debugDescription)
        scan.click()
        let controls = app.descendants(matching: .any)
        let search = controls["dashboard.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.click()
        search.typeText("not-found")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("resume")
        let matching = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Matching items: 2", "Matching items: 2")).firstMatch
        XCTAssertTrue(matching.waitForExistence(timeout: 5), app.debugDescription)
        controls["dashboard.selectedOnly"].firstMatch.click()
        let oneMatch = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Matching items: 1", "Matching items: 1")).firstMatch
        XCTAssertTrue(oneMatch.waitForExistence(timeout: 5), app.debugDescription)
        let hiddenCount = "Selected outside filters: 2"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", hiddenCount, hiddenCount)).firstMatch.exists)

        app.buttons["dashboard.review"].click()
        let cancel = app.buttons["cleanup.review.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let review = app.sheets.firstMatch
        for path in ["Library/Caches/Résumé build.log", "Library/Caches/Render.log", "Library/Caches/ollama"] {
            let suffix = "\(root.lastPathComponent)/\(path)"
            let listed = review.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", suffix, suffix)).firstMatch
            XCTAssertTrue(listed.exists, "Missing selected path \(suffix)")
        }
        XCTAssertFalse(review.staticTexts[unchecked.lastPathComponent].exists)
        cancel.click()
        XCTAssertTrue(oneMatch.waitForExistence(timeout: 5))
        controls["dashboard.clearFilters"].firstMatch.click()
        let total = "3 of 25 selected"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", total, total)).firstMatch.exists)
        let category = controls["dashboard.category"].firstMatch
        category.click()
        let ai = app.menuItems["AI Apps"]
        XCTAssertTrue(ai.waitForExistence(timeout: 5), app.debugDescription)
        ai.click()
        XCTAssertTrue(oneMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", hiddenCount, hiddenCount)).firstMatch.exists)
        for file in [match, hidden, aiFile, unchecked] { XCTAssertEqual(try Data(contentsOf: file), original) }
    }

    func testCommandKSearchReturnAndEscape() throws {
        let run = UUID()
        _ = try makeFixture(for: run)
        let app = launchFixture(run, animationsEnabled: false)
        defer { app.terminate() }
        let scan = app.buttons["dashboard.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        let elements = app.descendants(matching: .any)
        let palette = elements["toolSwitcher.search"].firstMatch
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5), app.debugDescription)
        app.typeText("Space Explorer")
        XCTAssertTrue(elements["toolSwitcher.result.spaceExplorer"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(palette.exists, app.debugDescription)
        XCTAssertTrue(scan.isEnabled)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        app.typeText("Space Explorer")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(palette.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Choose Folder"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func makeFixture(for run: UUID) throws -> URL {
        continueAfterFailure = false
        let root = URL(fileURLWithPath: "/private/tmp/PureMacUITest-\(run.uuidString)", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for directory in ["Library/Caches", "Library/HTTPStorages"] {
            try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        return root
    }

    private func launchFixture(_ run: UUID, animationsEnabled: Bool = true, recoverAppFile: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUREMAC_UI_TEST_RUN"] = run.uuidString
        if recoverAppFile { app.launchEnvironment["PUREMAC_UI_TEST_APP_RECOVERY"] = run.uuidString }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ApplePersistenceIgnoreState", "YES", "-settings.cleaning.excludedPaths", "()",
                               "-settings.general.animateInterface", animationsEnabled ? "YES" : "NO"]
        app.launch()
        return app
    }

    private func attachWindow(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
