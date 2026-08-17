import Foundation

enum Safety {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var deniedRoots: [String] {
        [
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Application Support/FileProvider",
            "\(home)/Library/Application Support/CloudDocs",
            "\(home)/Library/Daemon Containers",
            "\(home)/Library/Caches/CloudKit",
            "\(home)/Library/Caches/com.apple.bird",
            "\(home)/Library/Caches/com.apple.cloudkit",
            "\(home)/Library/Caches/com.apple.cloudd",
            "\(home)/Library/Caches/com.apple.FileProvider",
        ]
    }

    static var criticalRoots: Set<String> {
        [
            "/", home, "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
            "\(home)/Library", "\(home)/Library/Caches", "\(home)/Library/Application Support",
            "\(home)/Library/Containers", "\(home)/Library/Preferences", "\(home)/Library/Logs",
            "\(home)/Library/Developer", "\(home)/Library/Developer/Xcode",
            "\(home)/.config", "\(home)/.cache", "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
        ]
    }

    static func isSymlink(_ path: String) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
        return type == .typeSymbolicLink
    }

    static func isProviderOwned(_ path: String) -> Bool {
        let candidates = [
            (path as NSString).standardizingPath,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
        ]
        for candidate in candidates {
            if candidate.contains("com~apple~") { return true }
            for root in deniedRoots where candidate == root || candidate.hasPrefix(root + "/") { return true }
        }
        return false
    }

    static var deniedUserRoots: [String] {
        [".ssh", ".aws", ".gnupg", ".gpg", ".kube", ".docker", ".claude", ".config", ".cargo", ".rustup",
         ".gem", ".nvm", ".pyenv", ".rbenv", ".ollama", ".lmstudio"].map { "\(home)/\($0)" }
    }

    static func isCredentialRoot(_ path: String) -> Bool {
        for root in deniedUserRoots where path == root { return true }
        return false
    }

    static func canRemove(_ path: String, ignore: IgnoreStore) -> (ok: Bool, reason: String?) {
        let std = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        if std.isEmpty || std == "/" || resolved == "/" { return (false, "root path") }
        if criticalRoots.contains(std) || criticalRoots.contains(resolved) { return (false, "protected root") }
        if isCredentialRoot(std) || isCredentialRoot(resolved) { return (false, "config/credentials dir") }
        if isProviderOwned(std) { return (false, "cloud/provider state") }
        if ignore.isIgnored(std) || ignore.isIgnored(resolved) { return (false, "ignored") }
        if !FileManager.default.fileExists(atPath: std) { return (false, "missing") }
        return (true, nil)
    }

    static func isValidScanRoot(_ path: String) -> (ok: Bool, reason: String?) {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let std = (resolved as NSString).standardizingPath
        var systemRoots: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/Volumes", home]
        for dir in ["Library", "Pictures", "Music", "Movies", "Public"] { systemRoots.insert("\(home)/\(dir)") }
        if systemRoots.contains(std) { return (false, "'\(path)' is a system location — scan a project folder instead") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else {
            return (false, "not a folder: \(path)")
        }
        return (true, nil)
    }
}
