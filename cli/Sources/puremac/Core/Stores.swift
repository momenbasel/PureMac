import Foundation

enum AppPaths {
    static var configDir: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdg.isEmpty,
           xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("puremac", isDirectory: true)
    }

    static var ignoreFile: URL { configDir.appendingPathComponent("ignore") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }
    static var projectsFile: URL { configDir.appendingPathComponent("projects") }

    static func ensureDefaults(
        configFile: URL = configFile,
        ignoreFile: URL = ignoreFile,
        projectsFile: URL = projectsFile
    ) throws {
        let results = [
            Result { try createIfMissing(configFile, try ConfigStore.defaultFileData()) },
            Result { try createIfMissing(ignoreFile, Data()) },
            Result { try createIfMissing(projectsFile, PathListFile.contents(Purger.defaultRoots)) },
        ]
        for case .failure(let error) in results { throw error }
    }

    private static func createIfMissing(_ file: URL, _ data: Data) throws {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .withoutOverwriting)
    }
}

enum StoreError: LocalizedError {
    case invalidConfigFile(String)
    case unknownConfigKey(String)
    case invalidConfigValue(key: String, value: String)
    case invalidProjectRoot(String)
    case invalidProjectsFile(String)
    case invalidIgnorePath
    case invalidIgnoreFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfigFile(let path):
            return "Configuration file is not a valid PureMac settings file: \(path)"
        case .unknownConfigKey(let key):
            return "Unknown setting '\(key)'."
        case .invalidConfigValue(let key, let value):
            return "Invalid value '\(value)' for \(key). Use a whole number from 1 to 3650."
        case .invalidProjectRoot(let path):
            return "Project folders must be absolute paths: \(path)"
        case .invalidProjectsFile(let path):
            return "Project folders file contains an invalid or relative path: \(path)"
        case .invalidIgnorePath:
            return "Protected paths cannot be empty, the filesystem root, or contain newline or NUL characters."
        case .invalidIgnoreFile(let path):
            return "Ignore file contains an invalid or relative path: \(path)"
        }
    }
}

enum PathListFile {
    static func standardized(_ path: String, relativeTo currentDirectoryPath: String, allowRelative: Bool) -> String? {
        guard !path.isEmpty, !containsControl(path) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            guard allowRelative else { return nil }
            absolute = currentDirectoryPath + "/" + expanded
        }
        let standardized = lexicalStandardizedAbsolutePath(absolute)
        guard standardized != "/", !containsControl(standardized) else { return nil }
        return standardized
    }

    static func load(from fileURL: URL, invalid: Error) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var seen = Set<String>()
        var roots: [String] = []
        for line in contents.split(separator: "\n") {
            guard let root = standardized(String(line), relativeTo: "/", allowRelative: false) else { throw invalid }
            if seen.insert(root).inserted { roots.append(root) }
        }
        return roots
    }

    static func adding(_ root: String, to roots: [String], save: ([String]) throws -> Void) throws -> [String]? {
        guard !roots.contains(root) else { return nil }
        let updated = roots + [root]
        try save(updated)
        return updated
    }

    static func removing(_ root: String, from roots: [String], save: ([String]) throws -> Void) throws -> [String]? {
        guard roots.contains(root) else { return nil }
        let updated = roots.filter { $0 != root }
        try save(updated)
        return updated
    }

    static func contents(_ roots: [String]) -> Data {
        Data((roots.isEmpty ? "" : roots.joined(separator: "\n") + "\n").utf8)
    }

    static func save(_ roots: [String], to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents(roots).write(to: fileURL, options: .atomic)
    }

    private static func containsControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0 || CharacterSet.newlines.contains($0) }
    }

    private static func lexicalStandardizedAbsolutePath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }
}

struct ProjectFoldersStore {
    private(set) var roots: [String]
    private let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        roots = try PathListFile.load(from: fileURL, invalid: StoreError.invalidProjectsFile(fileURL.path))
            ?? Purger.defaultRoots
    }

    mutating func add(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(path)
        guard let updated = try PathListFile.adding(standardized, to: roots, save: { try PathListFile.save($0, to: fileURL) })
        else { return false }
        roots = updated
        return true
    }

    mutating func remove(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(path)
        guard let updated = try PathListFile.removing(standardized, from: roots, save: { try PathListFile.save($0, to: fileURL) })
        else { return false }
        roots = updated
        return true
    }

    private static func standardized(_ path: String) throws -> String {
        guard let standardized = PathListFile.standardized(path, relativeTo: "/", allowRelative: false) else {
            throw StoreError.invalidProjectRoot(path)
        }
        return standardized
    }
}

struct IgnoreStore {
    private(set) var roots: [String]
    private let fileURL: URL
    private let currentDirectoryPath: String

    init() {
        fileURL = AppPaths.ignoreFile
        currentDirectoryPath = FileManager.default.currentDirectoryPath
        roots = (try? Self.load(from: fileURL)) ?? []
    }

    init(
        fileURL: URL,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) throws {
        self.fileURL = fileURL
        self.currentDirectoryPath = currentDirectoryPath
        roots = try Self.load(from: fileURL)
    }

    func isIgnored(_ path: String) -> Bool {
        guard let standardized = try? Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        ) else { return false }
        for root in roots where standardized == root || standardized.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    mutating func add(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        )
        guard let updated = try PathListFile.adding(standardized, to: roots, save: save) else { return false }
        roots = updated
        return true
    }

    mutating func remove(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        )
        guard let updated = try PathListFile.removing(standardized, from: roots, save: save) else { return false }
        roots = updated
        return true
    }

    private static func standardized(
        _ path: String,
        relativeTo currentDirectoryPath: String,
        allowRelative: Bool
    ) throws -> String {
        guard let standardized = PathListFile.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: allowRelative
        ) else {
            throw StoreError.invalidIgnorePath
        }
        return standardized
    }

    private static func load(from fileURL: URL) throws -> [String] {
        try PathListFile.load(from: fileURL, invalid: StoreError.invalidIgnoreFile(fileURL.path)) ?? []
    }

    private func save(_ roots: [String]) throws {
        try PathListFile.save(roots.sorted(), to: fileURL)
    }
}

struct ConfigStore {
    private(set) var values: [String: String]
    private let fileURL: URL

    static let daysKey = "purge.older_than_days"
    static let knownKeys = [daysKey]
    static let defaultDays = 7

    var olderThanDays: Int { values[Self.daysKey].flatMap { Int($0) } ?? Self.defaultDays }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        values = try Self.load(from: fileURL)
    }

    mutating func set(_ key: String, _ value: String) throws {
        let normalized = try Self.normalizedValue(value, for: key)
        var updated = values
        updated[key] = normalized
        let data = try Self.encode(updated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        values = updated
    }

    static func normalizedValue(_ value: String, for key: String) throws -> String {
        guard knownKeys.contains(key) else {
            throw StoreError.unknownConfigKey(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(trimmed), (1...3650).contains(days) else {
            throw StoreError.invalidConfigValue(key: key, value: value)
        }
        return String(days)
    }

    static func defaultFileData() throws -> Data {
        try encode([daysKey: String(defaultDays)])
    }

    private static func encode(_ values: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func load(from fileURL: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: String]
        else {
            throw StoreError.invalidConfigFile(fileURL.path)
        }
        var normalized: [String: String] = [:]
        for (key, value) in values { normalized[key] = try normalizedValue(value, for: key) }
        return normalized
    }
}
