import XCTest

final class LocalizationFilesTests: XCTestCase {
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
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let strings = plist as? [String: String] else {
            XCTFail("\(fileURL.path) is not a valid Localizable.strings dictionary")
            return []
        }

        return Set(strings.keys)
    }
}
