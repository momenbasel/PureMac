import Foundation

/// One app bundle with localization folders the user's system does not need.
struct LanguageFileFinding: Sendable {
    /// A single removable localization folder inside Contents/Resources.
    struct Lproj: Sendable {
        /// Full path to the .lproj folder.
        let path: String
        /// Recursive size of the folder in bytes.
        let size: Int64
    }

    /// Bundle name without the .app suffix.
    let appName: String
    /// Full path to the .app bundle.
    let appPath: String
    /// Removable .lproj folders found in the bundle.
    let lprojs: [Lproj]
    /// True when Contents/_MASReceipt is present. An App Store update or
    /// re-download restores stripped localizations anyway, so callers should
    /// leave these findings unselected by default.
    let appStore: Bool

    /// Combined size of all removable folders in the bundle.
    var totalBytes: Int64 { lprojs.reduce(0) { $0 + $1.size } }
}

/// Finds unused .lproj localization folders inside installed app bundles
/// (the CleanMyMac "Language Files" feature). Pure logic - nothing is deleted
/// here. The integrator surfaces each removable .lproj as its own
/// CleanableItem (see `flatten`), and deletion runs through the existing
/// CleaningEngine.removeItem flow.
struct LanguageFilesScanner: Sendable {

    /// Normalized language keys that must never be flagged as removable.
    /// Built from Locale.preferredLanguages - "en-US" keeps "en" plus the
    /// "en-US"/"en_US" variants - and always includes en, English (the legacy
    /// folder name) and Base, which apps rely on as fallbacks.
    var keepLanguages: Set<String> {
        var keep: Set<String> = ["en", "english", "base"]
        for language in Locale.preferredLanguages {
            // "en-us" also keeps plain "en" so regional variants of a
            // preferred language survive.
            Self.insertWithBase(Self.normalize(language), into: &keep)
        }
        return keep
    }

    /// Scans the given application directories (top level plus one nested
    /// level, e.g. /Applications/Utilities) and returns one finding per app
    /// bundle that has removable localizations. Apps under /System and the
    /// PureMac bundle itself are never reported.
    func scan(applicationDirs: [String]) -> [LanguageFileFinding] {
        let fileManager = FileManager.default
        let keep = keepLanguages
        let ownPath = (Bundle.main.bundlePath as NSString).standardizingPath

        var findings: [LanguageFileFinding] = []
        for dir in applicationDirs {
            for appPath in appBundles(in: dir, fileManager: fileManager) {
                if let finding = inspect(appPath: appPath, keep: keep, ownPath: ownPath, fileManager: fileManager) {
                    findings.append(finding)
                }
            }
        }

        return findings.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Expands per-app findings into one entry per removable .lproj so the
    /// integrator can surface each folder as its own CleanableItem. Entries
    /// are named "<App> - <language display name>".
    func flatten(_ findings: [LanguageFileFinding]) -> [(name: String, path: String, size: Int64, appStore: Bool)] {
        findings.flatMap { finding in
            finding.lprojs.map { lproj in
                let code = ((lproj.path as NSString).lastPathComponent as NSString).deletingPathExtension
                let identifier = code.replacingOccurrences(of: "_", with: "-")
                let display = Locale.current.localizedString(forIdentifier: identifier) ?? code
                return (name: "\(finding.appName) - \(display)", path: lproj.path, size: lproj.size, appStore: finding.appStore)
            }
        }
    }

    // MARK: - Private

    /// Lowercases and unifies separators so "pt_BR", "pt-BR" and "pt-br" all
    /// compare equal.
    private static func normalize(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Inserts a normalized language plus its base, so "pt-br" also keeps
    /// plain "pt".
    private static func insertWithBase(_ normalized: String, into keep: inout Set<String>) {
        keep.insert(normalized)
        if let base = normalized.split(separator: "-").first {
            keep.insert(String(base))
        }
    }

    /// Lists .app bundles at the top level of `dir` and one nested level
    /// below it. A missing directory (e.g. ~/Applications) is treated as
    /// empty.
    private func appBundles(in dir: String, fileManager: FileManager) -> [String] {
        guard let topLevel = try? fileManager.contentsOfDirectory(atPath: dir) else { return [] }

        var bundles: [String] = []
        for entry in topLevel {
            let path = dir + "/" + entry
            if entry.hasSuffix(".app") {
                bundles.append(path)
            } else if isDirectory(path, fileManager: fileManager) {
                guard let nested = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
                for sub in nested where sub.hasSuffix(".app") {
                    bundles.append(path + "/" + sub)
                }
            }
        }
        return bundles
    }

    /// Builds a finding for one bundle, or nil when the bundle is skipped or
    /// has nothing removable.
    private func inspect(appPath: String, keep: Set<String>, ownPath: String, fileManager: FileManager) -> LanguageFileFinding? {
        let standardized = (appPath as NSString).standardizingPath
        // System apps live on the sealed volume and PureMac must never offer
        // to strip itself.
        if standardized.hasPrefix("/System/") { return nil }
        if standardized == ownPath { return nil }
        if (standardized as NSString).lastPathComponent == "PureMac.app" { return nil }

        let resourcesPath = appPath + "/Contents/Resources"
        guard isDirectory(resourcesPath, fileManager: fileManager) else { return nil }

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: resourcesPath)
        } catch {
            Logger.shared.log("Cannot read \(resourcesPath): \(error.localizedDescription)", level: .warning)
            return nil
        }

        // A bundle with a single .lproj keeps it regardless of language —
        // it is the app's only (and therefore primary) localization, often
        // holding its nibs and storyboards.
        let lprojCount = contents.filter { $0.lowercased().hasSuffix(".lproj") }.count
        guard lprojCount > 1 else { return nil }

        // Per-bundle keep set: the global set plus this bundle's development
        // region — NSBundle's fallback chain ends there, and for apps
        // developed in a non-English region it is often the only complete
        // localization — and any per-app language override the user set in
        // System Settings > Language & Region > Applications.
        var keep = keep
        let infoPlist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
        if let region = infoPlist?["CFBundleDevelopmentRegion"] as? String {
            Self.insertWithBase(Self.normalize(region), into: &keep)
        }
        if let bundleID = infoPlist?["CFBundleIdentifier"] as? String,
           let override = CFPreferencesCopyValue(
               "AppleLanguages" as CFString, bundleID as CFString,
               kCFPreferencesCurrentUser, kCFPreferencesAnyHost
           ) as? [String] {
            for language in override {
                Self.insertWithBase(Self.normalize(language), into: &keep)
            }
        }

        var lprojs: [LanguageFileFinding.Lproj] = []
        for entry in contents where entry.lowercased().hasSuffix(".lproj") {
            let language = String(entry.dropLast(".lproj".count))
            guard !keep.contains(Self.normalize(language)) else { continue }

            let lprojPath = resourcesPath + "/" + entry
            // A symlinked .lproj points at content shared elsewhere in the
            // bundle; removing it could break the target, so leave it alone.
            if let type = (try? fileManager.attributesOfItem(atPath: lprojPath))?[.type] as? FileAttributeType,
               type == .typeSymbolicLink { continue }

            lprojs.append(.init(path: lprojPath, size: directorySize(path: lprojPath, fileManager: fileManager)))
        }

        guard !lprojs.isEmpty else { return nil }

        let appStore = fileManager.fileExists(atPath: appPath + "/Contents/_MASReceipt")
        let appName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return LanguageFileFinding(appName: appName, appPath: appPath, lprojs: lprojs, appStore: appStore)
    }

    /// Recursive size of one .lproj. Localization folders stay small, so no
    /// entry cap is applied; unreadable entries are skipped, not fatal.
    private func directorySize(path: String, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  let isFile = values.isRegularFile, isFile,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }
        return totalSize
    }

    private func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
