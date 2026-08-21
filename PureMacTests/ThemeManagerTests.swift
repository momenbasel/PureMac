import AppKit
import XCTest
@testable import PureMac

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var originalRawValue: String?
    private var originalMode: AppearanceMode = .system
    private var originalApplicationAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        originalRawValue = UserDefaults.standard.string(forKey: "PureMac.Appearance")
        originalMode = ThemeManager.shared.appearance
        originalApplicationAppearance = NSApp.appearance
    }

    override func tearDown() {
        // Reset the singleton first: @AppStorage caches writes made through the
        // wrapper, so changing UserDefaults directly is not enough to restore
        // the value ThemeManager reads when applying the process-wide theme.
        ThemeManager.shared.appearance = originalMode

        // Preserve the exact defaults representation as well (including an
        // absent or previously invalid value) and restore the AppKit override
        // independently so this suite cannot leak appearance state.
        if let originalRawValue {
            UserDefaults.standard.set(originalRawValue, forKey: "PureMac.Appearance")
        } else {
            UserDefaults.standard.removeObject(forKey: "PureMac.Appearance")
        }
        NSApp.appearance = originalApplicationAppearance
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
