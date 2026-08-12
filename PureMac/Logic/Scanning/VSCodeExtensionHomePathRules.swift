import Foundation

/// Deterministic `~` / `~/.config` association rules for VS Code–family extensions.
///
/// Personalization data under home is high-confidence when the directory name
/// equals the extension `name`, `publisher`, `publisher-name`, or dashed
/// `extensionId` — never via fuzzy whole-home search. Ultra-generic tokens
/// (python, docker, github, …) are denied so CLI/tool dirs are not claimed.
enum VSCodeExtensionHomePathRules {
    private static let minTokenLength = 5

    private static let deniedNames: Set<String> = [
        "python", "java", "rust", "ruby", "php", "yaml", "xml", "json",
        "markdown", "docker", "git", "node", "npm", "ssh", "remote",
        "theme", "icons", "debug", "test", "html", "css", "sql", "shell",
        "bash", "zsh", "vim", "code", "editor", "go", "cpp", "c",
    ]

    private static let deniedPublishers: Set<String> = [
        "microsoft", "google", "amazon", "apple", "docker", "meta",
        "oracle", "ibm", "github",
    ]

    /// Relative paths under the home directory (POSIX, leading `.` for home dots).
    static func candidateRelativePaths(extensionId: String) -> [String] {
        guard let (publisher, name) = splitExtensionId(extensionId) else { return [] }
        let pub = publisher.lowercased()
        let nam = name.lowercased()
        let dashedId = extensionId.lowercased().replacingOccurrences(of: ".", with: "-")

        var out: [String] = []
        func add(_ relative: String) {
            if !out.contains(relative) { out.append(relative) }
        }

        if isAllowedName(nam) {
            add(".\(nam)")
            add(".config/\(nam)")
        }
        if isAllowedPublisher(pub) {
            add(".\(pub)")
            add(".config/\(pub)")
        }
        add(".\(pub)-\(nam)")
        add(".\(pub)_\(nam)")
        add(".\(extensionId.lowercased())")
        add(".config/\(pub)-\(nam)")
        add(".config/\(pub)_\(nam)")
        add(".config/\(dashedId)")

        return out
    }

    static func isAssociated(
        path: String,
        extensionId: String,
        homeDirectoryPath: String
    ) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = (homeDirectoryPath as NSString).standardizingPath
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(prefix) else { return false }
        // Never allow entire ~/.config (or other blocked roots as exact path).
        if isBlockedExactHomePath(normalized, home: home) { return false }

        let relative = String(normalized.dropFirst(prefix.count))
        let candidates = Set(candidateRelativePaths(extensionId: extensionId).map { $0.lowercased() })
        return candidates.contains(relative.lowercased())
    }

    /// Home personalization leftovers: `~/.token` or `~/.config/token` only.
    static func isHomePersonalizationPath(_ url: URL, homeDirectory: URL) -> Bool {
        let normalized = (url.path as NSString).standardizingPath
        let home = (homeDirectory.path as NSString).standardizingPath
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(prefix) else { return false }
        let relative = String(normalized.dropFirst(prefix.count))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count == 1, parts[0].hasPrefix("."), parts[0] != ".config" {
            return true
        }
        if parts.count == 2, parts[0] == ".config", !parts[1].isEmpty {
            return true
        }
        return false
    }

    static func defaultSelectedPaths(from urls: [URL], homeDirectory: URL) -> Set<URL> {
        Set(urls.filter { !isHomePersonalizationPath($0, homeDirectory: homeDirectory) })
    }

    /// Existing home leftovers for an extensionId (existence-checked).
    static func existingPaths(
        extensionId: String,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        for relative in candidateRelativePaths(extensionId: extensionId) {
            let url = homeDirectory.appendingPathComponent(relative, isDirectory: true)
            var isDir: ObjCBool = false
            // Also accept files (rare) at the same relative path.
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isBlockedExactHomePath(
                    (url.path as NSString).standardizingPath,
                    home: (homeDirectory.path as NSString).standardizingPath
                ) {
                    continue
                }
                urls.append(url)
            }
        }
        return urls
    }

    private static func splitExtensionId(_ extensionId: String) -> (String, String)? {
        let parts = extensionId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let publisher = String(parts[0])
        let name = String(parts[1])
        guard !publisher.isEmpty, !name.isEmpty else { return nil }
        return (publisher, name)
    }

    private static func isAllowedName(_ name: String) -> Bool {
        name.count >= minTokenLength && !deniedNames.contains(name)
    }

    private static func isAllowedPublisher(_ publisher: String) -> Bool {
        publisher.count >= minTokenLength && !deniedPublishers.contains(publisher)
    }

    private static func isBlockedExactHomePath(_ normalized: String, home: String) -> Bool {
        let blockedExact: Set<String> = [
            "\(home)/.config",
            "\(home)/.ssh",
            "\(home)/.aws",
            "\(home)/.gnupg",
            "\(home)/.docker",
            "\(home)/.git",
            "\(home)/.claude",
            "\(home)/.vscode",
            "\(home)/.local",
            "\(home)/.npm",
            "\(home)/.cache",
        ]
        return blockedExact.contains(normalized)
    }
}
