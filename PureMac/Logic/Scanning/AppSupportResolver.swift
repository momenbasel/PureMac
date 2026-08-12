import Foundation

/// Maps `~/.{editor}` dot-directories to one or more
/// `~/Library/Application Support/...` data directories used by VS Code forks.
enum AppSupportResolver {
    private static let aliases: [String: [String]] = [
        "vscode": ["Code"],
        "vscode-insiders": ["Code - Insiders"],
        "vscode-oss": ["VSCodium"],
    ]

    static func resolve(
        editorDotDirectory: String,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let supportRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: supportRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: supportRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let key = normalizeKey(editorDotDirectory)
        var wantedNames = Set(aliases[key] ?? [])
        wantedNames.insert(editorDotDirectory.hasPrefix(".")
            ? String(editorDotDirectory.dropFirst())
            : editorDotDirectory)

        var matches: [URL] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let name = child.lastPathComponent
            if namesMatch(candidate: name, wanted: wantedNames, normalizedKey: key) {
                matches.append(child)
            }
        }
        return matches.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func normalizeKey(_ editorDotDirectory: String) -> String {
        let trimmed = editorDotDirectory.hasPrefix(".")
            ? String(editorDotDirectory.dropFirst())
            : editorDotDirectory
        return trimmed.lowercased()
    }

    private static func namesMatch(candidate: String, wanted: Set<String>, normalizedKey: String) -> Bool {
        let candidateFolded = fold(candidate)
        if wanted.contains(where: { fold($0) == candidateFolded }) {
            return true
        }
        // Hyphen / space insensitive: trae-cn ↔ Trae CN
        return fold(normalizedKey) == candidateFolded
    }

    private static func fold(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
