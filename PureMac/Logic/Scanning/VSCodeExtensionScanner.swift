import Foundation

/// Discovered VS Code–family extension folder (one marketplace install).
struct VSCodeExtensionItem: Equatable, Identifiable {
    var id: String { path }
    let editorLabel: String
    let displayName: String
    let path: String
    let size: Int64
    let lastModified: Date?
    let extensionId: String
    let editorDotDirectory: String

    var listName: String { "\(editorLabel) · \(displayName)" }
}

/// Discovers VS Code–compatible extensions under `~/.*/extensions` without a
/// hardcoded editor allow-list.
///
/// Unified rule:
/// - Editor root shape: `~/.{name}/extensions/{extensionFolder}`
/// - Extension folder is included only when its `package.json` declares
///   `engines.vscode` (the VS Code compatibility marker used by forks).
enum VSCodeExtensionScanner {
    static func scan(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [VSCodeExtensionItem] {
        scanDotDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    /// True when `path` is inside `~/.{editor}/extensions/{ext}/…` and that
    /// extension folder's `package.json` declares `engines.vscode`.
    static func isSafeDeletePath(_ path: String, homeDirectoryPath: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = (homeDirectoryPath as NSString).standardizingPath
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(homePrefix) else { return false }

        let relative = String(normalized.dropFirst(homePrefix.count))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              parts[0].hasPrefix("."),
              parts[0] != ".",
              parts[0] != "..",
              !parts[0].contains(".."),
              parts[1] == "extensions",
              !parts[2].isEmpty,
              !parts[2].hasPrefix(".")
        else {
            return false
        }

        let extensionDir = [parts[0], "extensions", parts[2]].reduce(home) { partial, component in
            (partial as NSString).appendingPathComponent(component)
        }
        return hasVSCodeEngine(packageJSONAt: URL(fileURLWithPath: extensionDir).appendingPathComponent("package.json"))
    }

    // MARK: - Private

    private static func scanDotDirectories(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [VSCodeExtensionItem] {
        guard let homeContents = try? fileManager.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var items: [VSCodeExtensionItem] = []
        for entry in homeContents {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), name != ".", name != ".." else { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let extensionsRoot = entry.appendingPathComponent("extensions", isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: extensionsRoot.path, isDirectory: &isDir),
                  isDir.boolValue
            else {
                continue
            }

            let editorLabel = editorLabel(fromDotDirectory: name)
            guard let children = try? fileManager.contentsOfDirectory(
                at: extensionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard childValues?.isDirectory == true else { continue }
                if child.lastPathComponent.hasPrefix(".") { continue }
                let packageURL = child.appendingPathComponent("package.json")
                guard let meta = readExtensionMetadata(from: packageURL), meta.hasVSCodeEngine else {
                    continue
                }
                let size = FileSizeCalculator.size(of: child) ?? 0
                items.append(
                    VSCodeExtensionItem(
                        editorLabel: editorLabel,
                        displayName: meta.displayName,
                        path: (child.path as NSString).standardizingPath,
                        size: size,
                        lastModified: childValues?.contentModificationDate,
                        extensionId: meta.extensionId,
                        editorDotDirectory: name
                    )
                )
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    static func editorLabel(fromDotDirectory name: String) -> String {
        let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
        return trimmed
            .split(separator: "-")
            .map { part -> String in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst()
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct ExtensionMetadata {
        let displayName: String
        let extensionId: String
        let hasVSCodeEngine: Bool
    }

    private static func readExtensionMetadata(from packageURL: URL) -> ExtensionMetadata? {
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let displayName: String
        if let name = json["displayName"] as? String, !name.isEmpty {
            displayName = name
        } else if let name = json["name"] as? String, !name.isEmpty {
            displayName = name
        } else {
            displayName = packageURL.deletingLastPathComponent().lastPathComponent
        }
        let publisher = (json["publisher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extensionId: String
        if !publisher.isEmpty, !name.isEmpty {
            extensionId = "\(publisher).\(name)"
        } else {
            // Fallback: strip version suffix from folder name best-effort.
            extensionId = packageURL.deletingLastPathComponent().lastPathComponent
        }
        return ExtensionMetadata(
            displayName: displayName,
            extensionId: extensionId,
            hasVSCodeEngine: hasVSCodeEngine(in: json)
        )
    }

    private static func hasVSCodeEngine(packageJSONAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return hasVSCodeEngine(in: json)
    }

    private static func hasVSCodeEngine(in json: [String: Any]) -> Bool {
        guard let engines = json["engines"] as? [String: Any] else { return false }
        if let value = engines["vscode"] as? String, !value.isEmpty { return true }
        // Some manifests use a non-string placeholder; presence is enough.
        return engines["vscode"] != nil
    }
}
