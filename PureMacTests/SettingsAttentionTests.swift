import XCTest
@testable import PureMac

final class SettingsAttentionTests: XCTestCase {
    func testHealthyAndUncheckedSettingsDoNotCreateFalseWarnings() {
        XCTAssertTrue(SettingsAttention.issues(hasFullDiskAccess: true, updateState: .idle).isEmpty)
        XCTAssertTrue(SettingsAttention.issues(hasFullDiskAccess: true, updateState: .checking).isEmpty)
        XCTAssertTrue(SettingsAttention.issues(hasFullDiskAccess: true, updateState: .upToDate).isEmpty)
    }

    func testActionableProblemsPointToTheRightSettingsPage() {
        let issues = SettingsAttention.issues(hasFullDiskAccess: false, updateState: .failed("Offline"), needsRestart: true, startupError: "Unavailable")
        XCTAssertEqual(issues, [.diskAccess, .startup, .restart, .updateFailed])
        XCTAssertFalse(SettingsAttention.Issue.diskAccess.opensUpdates)
        XCTAssertTrue(SettingsAttention.Issue.updateFailed.opensUpdates)
        XCTAssertTrue(SettingsAttention.issues(hasFullDiskAccess: true, updateState: .upToDate).isEmpty)
    }

    func testAvailableUpdateIsActionableButNotInventedForNewerLocalBuilds() throws {
        let data = Data(#"[{"tag_name":"v3.1.0","html_url":"https://github.com/momenbasel/PureMac/releases/tag/v3.1.0","draft":false,"prerelease":false,"assets":[{"name":"PureMac-3.1.0.zip"}]}]"#.utf8)
        let release = try UpdateService.latestAppRelease(in: data)
        XCTAssertEqual(SettingsAttention.issues(hasFullDiskAccess: true, updateState: .available(release)), [.updateAvailable])
    }
}
