import XCTest
@testable import PureMac

final class AppLanguagePreferencesTests: XCTestCase {
    func testGermanRussianAndUkrainianLanguagesUseExpectedIdentifiers() {
        XCTAssertEqual(AppLanguage.german.rawValue, "de")
        XCTAssertEqual(AppLanguage.russian.rawValue, "ru")
        XCTAssertEqual(AppLanguage.ukrainian.rawValue, "uk")
        XCTAssertTrue(AppLanguage.allCases.contains(.german))
        XCTAssertTrue(AppLanguage.allCases.contains(.russian))
        XCTAssertTrue(AppLanguage.allCases.contains(.ukrainian))
    }

    func testApplyCustomLanguageSetsAppleLanguagesAndPreservesLocale() {
        let context = makeDefaults()
        let defaults = context.defaults
        defaults.set("pt_BR", forKey: "AppleLocale")

        AppLanguagePreferences.apply(.english, defaults: defaults)

        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["en"])
        XCTAssertEqual(defaults.string(forKey: "AppleLocale"), "pt_BR")
    }

    func testApplyGermanRussianAndUkrainianLanguagesSetsAppleLanguages() {
        let context = makeDefaults()
        let defaults = context.defaults

        AppLanguagePreferences.apply(.german, defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["de"])

        AppLanguagePreferences.apply(.russian, defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["ru"])

        AppLanguagePreferences.apply(.ukrainian, defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["uk"])
    }

    func testApplySystemLanguageRemovesAppleLanguagesAndPreservesLocale() {
        let context = makeDefaults()
        let defaults = context.defaults
        defaults.set(["en"], forKey: "AppleLanguages")
        defaults.set("pt_BR", forKey: "AppleLocale")

        AppLanguagePreferences.apply(.system, defaults: defaults)

        XCTAssertNil(defaults.persistentDomain(forName: context.suiteName)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "AppleLocale"), "pt_BR")
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PureMacTests.AppLanguagePreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
