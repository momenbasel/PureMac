import Foundation

enum AppPaths {
    static var configDir: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("puremac", isDirectory: true)
    }

    static var ignoreFile: URL { configDir.appendingPathComponent("ignore") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }
}

struct IgnoreStore {
    private(set) var roots: [String]

    init() {
        if let data = try? String(contentsOf: AppPaths.ignoreFile, encoding: .utf8) {
            roots = data.split(separator: "\n").map(String.init)
                .map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
                .filter { !$0.isEmpty }
        } else {
            roots = []
        }
    }

    func isIgnored(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        for root in roots where std == root || std.hasPrefix(root + "/") { return true }
        return false
    }

    mutating func add(_ path: String) throws -> Bool {
        let std = (((path as NSString).expandingTildeInPath) as NSString).standardizingPath
        guard !roots.contains(std) else { return false }
        roots.append(std)
        try save()
        return true
    }

    mutating func remove(_ path: String) throws -> Bool {
        let std = (((path as NSString).expandingTildeInPath) as NSString).standardizingPath
        guard let idx = roots.firstIndex(of: std) else { return false }
        roots.remove(at: idx)
        try save()
        return true
    }

    private func save() throws {
        AppPaths.ensureDir()
        try (roots.sorted().joined(separator: "\n") + "\n").write(to: AppPaths.ignoreFile, atomically: true, encoding: .utf8)
    }
}

struct ConfigStore {
    var values: [String: String]

    static let knownKeys = ["purge.older_than_days"]

    init() {
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            values = obj
        } else {
            values = [:]
        }
    }

    mutating func set(_ key: String, _ value: String) {
        values[key] = value
        save()
    }

    private func save() {
        AppPaths.ensureDir()
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: AppPaths.configFile)
        }
    }
}
