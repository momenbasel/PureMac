import XCTest

final class LocalizationFilesTests: XCTestCase {
    func testRussianAndUkrainianLocalizationsExist() throws {
        let localizationFiles = try localizableStringsFiles()

        XCTAssertNotNil(localizationFiles["ru"], "Expected ru.lproj/Localizable.strings to exist")
        XCTAssertNotNil(localizationFiles["uk"], "Expected uk.lproj/Localizable.strings to exist")
    }

    func testChinesePermissionAndFinderMenuLocalizationsExist() throws {
        for language in ["zh-Hans", "zh-Hant"] {
            XCTAssertNotNil(
                Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language),
                "Expected the built app to include the \(language) permission prompt localization"
            )
            XCTAssertNotNil(
                Bundle.main.path(forResource: "ServicesMenu", ofType: "strings", inDirectory: nil, forLocalization: language),
                "Expected the built app to include the \(language) Finder Services localization"
            )
        }
    }

    func testBuiltAppBundleContainsRussianAndUkrainianLocalizations() throws {
        for language in ["ru", "uk"] {
            XCTAssertTrue(
                Bundle.main.localizations.contains(language),
                "Expected the built app bundle to register the \(language) localization"
            )
            for resource in ["Localizable", "InfoPlist", "ServicesMenu"] {
                XCTAssertNotNil(
                    Bundle.main.path(
                        forResource: resource,
                        ofType: "strings",
                        inDirectory: nil,
                        forLocalization: language
                    ),
                    "Expected the built app bundle to contain \(language).lproj/\(resource).strings"
                )
            }

            let localizablePath = try XCTUnwrap(
                Bundle.main.path(
                    forResource: "Localizable",
                    ofType: "strings",
                    inDirectory: nil,
                    forLocalization: language
                )
            )
            let localizationPath = URL(fileURLWithPath: localizablePath)
                .deletingLastPathComponent()
                .path
            let localizationBundle = try XCTUnwrap(Bundle(path: localizationPath))
            XCTAssertNotEqual(
                localizationBundle.localizedString(forKey: "Language", value: nil, table: nil),
                "Language",
                "Expected the \(language) localization bundle to resolve a translated sentinel value"
            )
        }
    }

    func testAllLocalizableStringsFilesHaveEnglishKeyParity() throws {
        let localizationFiles = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(
            localizationFiles["en"],
            "Expected en.lproj/Localizable.strings to exist"
        )
        let englishKeys = try localizedKeys(in: englishURL)

        for (language, fileURL) in localizationFiles where language != "en" {
            let languageKeys = try localizedKeys(in: fileURL)
            let missingKeys = englishKeys.subtracting(languageKeys).sorted()
            let extraKeys = languageKeys.subtracting(englishKeys).sorted()

            XCTAssertTrue(
                missingKeys.isEmpty,
                "\(language).lproj/Localizable.strings is missing keys:\n\(missingKeys.joined(separator: "\n"))"
            )
            XCTAssertTrue(
                extraKeys.isEmpty,
                "\(language).lproj/Localizable.strings has extra keys:\n\(extraKeys.joined(separator: "\n"))"
            )
        }
    }

    func testChineseLocalizationsDoNotLeaveEnglishEntriesUntranslated() throws {
        let localizationFiles = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(localizationFiles["en"])
        let englishStrings = try localizedStrings(in: englishURL)
        let technicalTerms = Set(["Qpure", "Qpure.app", "Finder", "CPU", "Time Machine", "%lld", "%lld × %lld", "%lld%%"])

        for language in ["zh-Hans", "zh-Hant"] {
            let fileURL = try XCTUnwrap(localizationFiles[language])
            let localized = try localizedStrings(in: fileURL)
            let untranslated: [String] = englishStrings.compactMap { key, englishValue -> String? in
                guard
                    !technicalTerms.contains(key),
                    englishValue.rangeOfCharacter(from: .letters) != nil,
                    localized[key] == englishValue
                else { return nil }
                return key
            }.sorted()

            XCTAssertTrue(
                untranslated.isEmpty,
                "\(language).lproj still has English values for:\n\(untranslated.joined(separator: "\n"))"
            )
        }
    }

    func testChineseDashboardAndCategoryEmptyStateStringsAreTranslated() throws {
        let files = try localizableStringsFiles()
        let keys = [
            "Tools",
            "Focused utilities for storage, apps, and system maintenance",
            "Space Explorer",
            "Duplicate Finder",
            "Similar Photos",
            "Uninstaller",
            "App Updates",
            "Protection",
            "Performance",
            "Find what uses the most disk space",
            "Review matching files side by side",
            "Compare visually similar photos",
            "Remove apps and their related files",
            "Check installed apps for new versions",
            "Review built-in privacy and safety checks",
            "Inspect memory and background activity",
            "See what is taking up space",
            "Scan first, then review the exact files before removing anything.",
            "Scan this category"
        ]

        let english = try localizedStrings(in: XCTUnwrap(files["en"]))
        for language in ["zh-Hans", "zh-Hant"] {
            let localized = try localizedStrings(in: XCTUnwrap(files[language]))
            for key in keys {
                XCTAssertNotEqual(
                    localized[key],
                    english[key],
                    "Expected \(language) to translate the visible UI string: \(key)"
                )
            }
        }
    }

    func testStaticSwiftUIStringsHaveEnglishLocalizationKeys() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PureMac/Views")
        let englishKeys = try localizedKeys(in: XCTUnwrap(localizableStringsFiles()["en"]))
        let patterns = [
            #"\b(?:Text|Button|Label|Section|TextField|Toggle|Picker|LabeledContent|EmptyStateView|SectionHeader|StatusChip|dashboardSection|sectionLabel)\(\s*\"((?:\\.|[^\"\\])*)\""#,
            #"\.(?:navigationTitle|help|accessibilityLabel|accessibilityValue|alert|confirmationDialog)\(\s*\"((?:\\.|[^\"\\])*)\""#,
            #"\b(?:title|detail|message|label):\s*\"((?:\\.|[^\"\\])*)\""#
        ]
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var missing: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for expression in expressions {
                for match in expression.matches(in: source, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                    let key = String(source[keyRange])
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                    guard !key.isEmpty, !key.contains("\\(") else { continue }
                    if !englishKeys.contains(key) {
                        missing.append("\(fileURL.lastPathComponent): \(key)")
                    }
                }
            }
        }

        XCTAssertTrue(missing.isEmpty, "Static SwiftUI strings missing English keys:\n\(missing.sorted().joined(separator: "\n"))")
    }

    func testStringLocalizedCallsHaveEnglishResourceKeys() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PureMac")
        let englishURL = try XCTUnwrap(localizableStringsFiles()["en"])
        let englishKeys = try localizedKeys(in: englishURL)
        let regex = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:\\.|[^"\\])*)""#)
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var missing: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                if !englishKeys.contains(key) {
                    missing.append("\(fileURL.lastPathComponent): \(key)")
                }
            }
        }

        XCTAssertTrue(missing.isEmpty, "Missing Localizable.strings keys:\n\(missing.sorted().joined(separator: "\n"))")
    }

    func testAllLocalizedValuesPreserveEnglishFormatSpecifiers() throws {
        let localizationFiles = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(localizationFiles["en"])
        let englishStrings = try localizedStrings(in: englishURL)

        for (language, fileURL) in localizationFiles where language != "en" {
            let localizedStrings = try localizedStrings(in: fileURL)

            for (key, englishValue) in englishStrings {
                let localizedValue = try XCTUnwrap(localizedStrings[key])
                XCTAssertEqual(
                    formatSignature(in: localizedValue),
                    formatSignature(in: englishValue),
                    "\(language).lproj has incompatible format specifiers for key: \(key)"
                )
            }
        }
    }

    func testLocalizableStringsFilesDoNotContainDuplicateKeys() throws {
        for (language, fileURL) in try localizableStringsFiles() {
            let keys = try declaredKeys(in: fileURL)
            let duplicates = Dictionary(grouping: keys, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
                .sorted()

            XCTAssertTrue(
                duplicates.isEmpty,
                "\(language).lproj/Localizable.strings has duplicate keys:\n\(duplicates.joined(separator: "\n"))"
            )
        }
    }

    private func localizableStringsFiles() throws -> [String: URL] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSourceDirectory = sourceRoot.appendingPathComponent("PureMac")
        let contents = try FileManager.default.contentsOfDirectory(
            at: appSourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return contents.reduce(into: [String: URL]()) { result, url in
            guard url.pathExtension == "lproj",
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Localizable.strings").path)
            else {
                return
            }

            result[url.deletingPathExtension().lastPathComponent] = url.appendingPathComponent("Localizable.strings")
        }
    }

    private func localizedKeys(in fileURL: URL) throws -> Set<String> {
        Set(try localizedStrings(in: fileURL).keys)
    }

    private func localizedStrings(in fileURL: URL) throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let strings = plist as? [String: String] else {
            XCTFail("\(fileURL.path) is not a valid Localizable.strings dictionary")
            return [:]
        }

        return strings
    }

    private func declaredKeys(in fileURL: URL) throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^"((?:\\.|[^"])*)"\s*="#)
        let range = NSRange(contents.startIndex..., in: contents)

        return regex.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { String(contents[$0]) }
        }
    }

    private func formatSignature(in value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?(lld|@|%)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        var sequentialPosition = 1

        return regex.matches(in: value, range: range).compactMap { match in
            guard let typeRange = Range(match.range(at: 2), in: value) else { return nil }
            let type = String(value[typeRange])
            guard type != "%" else { return "literal-percent" }

            if let explicitRange = Range(match.range(at: 1), in: value),
               let position = Int(value[explicitRange]) {
                return "\(position):\(type)"
            }

            defer { sequentialPosition += 1 }
            return "\(sequentialPosition):\(type)"
        }
        .sorted()
    }
}
