import XCTest

final class LocalizationFilesTests: XCTestCase {
    func testRussianAndUkrainianLocalizationsExist() throws {
        let localizationFiles = try localizableStringsFiles()

        XCTAssertNotNil(localizationFiles["ru"], "Expected ru.lproj/Localizable.strings to exist")
        XCTAssertNotNil(localizationFiles["uk"], "Expected uk.lproj/Localizable.strings to exist")
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
