import XCTest
@testable import Qpure

final class ApplicationUpdaterTests: XCTestCase {
    func testAppIdentityMatcherResolvesKnownCaskNamesExactly() {
        let appNames = ["MiddleClick", "OpenSCAD", "Postman", "Pure Snitch"]

        XCTAssertEqual(AppUpdateIdentityMatcher.matchingIndex(for: "middleclick", appNames: appNames), 0)
        XCTAssertEqual(AppUpdateIdentityMatcher.matchingIndex(for: "openscad@snapshot", appNames: appNames), 1)
        XCTAssertEqual(AppUpdateIdentityMatcher.matchingIndex(for: "postman", appNames: appNames), 2)
        XCTAssertEqual(AppUpdateIdentityMatcher.matchingIndex(for: "puresnitch", appNames: appNames), 3)
    }

    func testAppIdentityMatcherStripsTapAndVariantBeforeMatching() {
        XCTAssertEqual(
            AppUpdateIdentityMatcher.matchingIndex(
                for: "vendor/tap/openscad@snapshot",
                appNames: ["OpenSCAD"]
            ),
            0
        )
        XCTAssertEqual(AppUpdateIdentityMatcher.baseToken("vendor/tap/openscad@snapshot"), "openscad")
        XCTAssertTrue(AppUpdateIdentityMatcher.shouldShowTokenDetail("openscad@snapshot"))
    }

    func testAppIdentityMatcherRejectsFuzzyAndAmbiguousMatches() {
        XCTAssertNil(
            AppUpdateIdentityMatcher.matchingIndex(
                for: "postman-agent",
                appNames: ["Postman"]
            )
        )
        XCTAssertNil(
            AppUpdateIdentityMatcher.matchingIndex(
                for: "foo-bar",
                appNames: ["Foo Bar", "Foo-Bar"]
            )
        )
    }

    func testAppIdentityFallbackProducesReadableName() {
        XCTAssertEqual(
            AppUpdateIdentityMatcher.fallbackDisplayName(for: "vendor/tap/visual-studio-code@insiders"),
            "Visual Studio Code"
        )
        XCTAssertFalse(AppUpdateIdentityMatcher.shouldShowTokenDetail("postman"))
    }

    func testParsesCaskNamesAndTrustedApplicationTargets() throws {
        let json = #"{"casks":[{"token":"openscad@snapshot","name":["OpenSCAD"],"artifacts":[{"app":["OpenSCAD.app"],"target":"/Applications/OpenSCAD.app"}]},{"token":"puresnitch","name":["PureSnitch"],"artifacts":[{"app":["PureSnitch.app"],"target":"/Applications/PureSnitch.app"}]}]}"#

        let descriptors = try ApplicationUpdater.parseCaskPresentationDescriptors(
            Data(json.utf8),
            requestedTokens: ["openscad@snapshot", "puresnitch"]
        )

        XCTAssertEqual(descriptors["openscad@snapshot"]?.displayName, "OpenSCAD")
        XCTAssertEqual(descriptors["openscad@snapshot"]?.bundlePaths, ["/Applications/OpenSCAD.app"])
        XCTAssertEqual(descriptors["puresnitch"]?.displayName, "PureSnitch")
    }

    func testCaskPresentationParserRejectsUntrustedTargets() throws {
        let json = #"{"casks":[{"token":"safe-app","name":["Safe App"],"artifacts":[{"app":["Safe.app"],"target":"/tmp/Safe.app"},{"app":["Default.app"]}]}]}"#

        let descriptors = try ApplicationUpdater.parseCaskPresentationDescriptors(
            Data(json.utf8),
            requestedTokens: ["safe-app"]
        )

        XCTAssertEqual(descriptors["safe-app"]?.bundlePaths, ["/Applications/Default.app"])
    }

    func testParsesOutdatedCasksWithInstalledAndAvailableVersions() throws {
        let json = """
        {
          "formulae": [],
          "casks": [
            {
              "name": "visual-studio-code",
              "installed_versions": ["1.98.0", "1.98.1"],
              "current_version": "1.99.0",
              "pinned": false,
              "pinned_version": null
            },
            {
              "name": "1password",
              "installed_versions": ["8.10.68"],
              "current_version": "8.10.70",
              "pinned": true,
              "pinned_version": "8.10.68"
            }
          ]
        }
        """

        let updates = try ApplicationUpdater.parseOutdatedCasks(json)

        XCTAssertEqual(updates.map(\.token), ["1password", "visual-studio-code"])
        XCTAssertEqual(updates[0].installedVersion, "8.10.68")
        XCTAssertEqual(updates[0].currentVersion, "8.10.70")
        XCTAssertTrue(updates[0].isPinned)
        XCTAssertEqual(updates[1].installedVersion, "1.98.0, 1.98.1")
        XCTAssertEqual(updates[1].currentVersion, "1.99.0")
        XCTAssertFalse(updates[1].isPinned)
    }

    func testParsesEmptyCaskList() throws {
        let updates = try ApplicationUpdater.parseOutdatedCasks(#"{"formulae":[],"casks":[]}"#)
        XCTAssertTrue(updates.isEmpty)
    }

    func testRejectsMalformedOrIncompletePayloads() {
        XCTAssertThrowsError(try ApplicationUpdater.parseOutdatedCasks("not-json")) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidResponse)
        }

        let missingVersion = #"{"casks":[{"name":"firefox","installed_versions":["1"]}]}"#
        XCTAssertThrowsError(try ApplicationUpdater.parseOutdatedCasks(missingVersion)) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidResponse)
        }

        let emptyInstalled = #"{"casks":[{"name":"firefox","installed_versions":[],"current_version":"2","pinned":false}]}"#
        XCTAssertThrowsError(try ApplicationUpdater.parseOutdatedCasks(emptyInstalled)) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidResponse)
        }
    }

    func testCaskIdentifierValidationAllowsOnlyStrictTokens() {
        let valid = [
            "firefox",
            "visual-studio-code",
            "font-fira-code@6",
            "app_name+preview.2"
        ]
        let invalid = [
            "",
            "Firefox",
            "--debug",
            "../firefox",
            "homebrew/cask/firefox",
            "fire fox",
            "firefox;open",
            "firefox\n--debug",
            String(repeating: "a", count: 129)
        ]

        valid.forEach { XCTAssertTrue(ApplicationUpdater.isValidCaskIdentifier($0), $0) }
        invalid.forEach { XCTAssertFalse(ApplicationUpdater.isValidCaskIdentifier($0), $0) }
    }

    func testParserRejectsUnsafeCaskIdentifier() {
        let json = #"{"casks":[{"name":"../firefox","installed_versions":["1"],"current_version":"2","pinned":false}]}"#

        XCTAssertThrowsError(try ApplicationUpdater.parseOutdatedCasks(json)) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidCaskIdentifier("../firefox"))
        }
    }

    func testParserRejectsDuplicateCaskIdentifiers() {
        let json = """
        {
          "casks": [
            {"name":"firefox","installed_versions":["1"],"current_version":"2","pinned":false},
            {"name":"firefox","installed_versions":["1"],"current_version":"2","pinned":false}
          ]
        }
        """

        XCTAssertThrowsError(try ApplicationUpdater.parseOutdatedCasks(json)) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidResponse)
        }
    }

    func testUpgradeArgumentsUseOptionTerminatorAndSeparateTokens() throws {
        let arguments = try ApplicationUpdater.upgradeArguments(
            caskTokens: ["firefox", "visual-studio-code"]
        )

        XCTAssertEqual(arguments, ["upgrade", "--cask", "--", "firefox", "visual-studio-code"])
    }

    func testUpgradeArgumentsRejectEmptyOrUnsafeSelections() {
        XCTAssertThrowsError(try ApplicationUpdater.upgradeArguments(caskTokens: [])) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .noSelection)
        }
        XCTAssertThrowsError(
            try ApplicationUpdater.upgradeArguments(caskTokens: ["firefox", "--debug"])
        ) { error in
            XCTAssertEqual(error as? ApplicationUpdaterError, .invalidCaskIdentifier("--debug"))
        }
    }

    func testBrewDiscoveryUsesOnlyTrustedPathsInPriorityOrder() {
        var inspected: [String] = []
        let url = ApplicationUpdater.findBrewExecutable { path in
            inspected.append(path)
            return path == "/usr/local/bin/brew"
        }

        XCTAssertEqual(url?.path, "/usr/local/bin/brew")
        XCTAssertEqual(inspected, ApplicationUpdater.trustedBrewPaths)
    }

    func testProcessRunnerCapturesSuccessfulOutput() async throws {
        let result = try await BrewProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            timeout: 2
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testProcessRunnerReturnsNonzeroExitStatus() async throws {
        let result = try await BrewProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 2
        )

        XCTAssertNotEqual(result.status, 0)
    }

    func testProcessRunnerTimesOut() async {
        do {
            _ = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ApplicationUpdaterError, .timedOut)
        }
    }

    func testProcessRunnerRejectsOutputBeyondCaptureLimit() async {
        do {
            _ = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/head"),
                arguments: ["-c", "5000000", "/dev/zero"],
                timeout: 5
            )
            XCTFail("Expected output limit error")
        } catch {
            XCTAssertEqual(error as? ApplicationUpdaterError, .outputLimitExceeded)
        }
    }

    func testProcessRunnerRespondsToTaskCancellation() async {
        let task = Task {
            try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 10
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
