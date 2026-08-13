import AppKit
import XCTest
@testable import PureMac

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var originalRawValue: String?

    override func setUp() {
        super.setUp()
        originalRawValue = UserDefaults.standard.string(forKey: "PureMac.Appearance")
    }

    override func tearDown() {
        // The test host is the real app bundle, so put the user's persisted
        // choice back and re-sync NSApp so the host window isn't left themed.
        if let originalRawValue {
            UserDefaults.standard.set(originalRawValue, forKey: "PureMac.Appearance")
        } else {
            UserDefaults.standard.removeObject(forKey: "PureMac.Appearance")
        }
        ThemeManager.shared.applyToApp()
        super.tearDown()
    }

    func testDarkSelectionAppliesAppKitAppearance() {
        ThemeManager.shared.appearance = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
    }

    func testLightSelectionAppliesAppKitAppearance() {
        ThemeManager.shared.appearance = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
    }

    /// Dark -> System must clear the app-level override entirely. The previous
    /// .preferredColorScheme(nil) pipeline left the NavigationSplitView content
    /// stuck in the old scheme until the window resigned key.
    func testSystemSelectionClearsAppKitAppearance() {
        ThemeManager.shared.appearance = .dark
        ThemeManager.shared.appearance = .system
        XCTAssertNil(NSApp.appearance)
    }

    func testSelectionPersistsAcrossManagerReads() {
        ThemeManager.shared.appearance = .dark
        XCTAssertEqual(UserDefaults.standard.string(forKey: "PureMac.Appearance"), "dark")
        XCTAssertEqual(ThemeManager.shared.appearance, .dark)
    }
}
