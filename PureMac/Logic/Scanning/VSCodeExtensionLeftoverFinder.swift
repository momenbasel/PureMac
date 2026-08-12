import Foundation

/// Finds leftover paths for a VS Code–family extension (install + storage/cache).
enum VSCodeExtensionLeftoverFinder {
    static func findRelatedPaths(
        for item: VSCodeExtensionItem,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        let install = URL(fileURLWithPath: item.path)
        if fileManager.fileExists(atPath: install.path) {
            urls.append(install)
        }

        let supports = AppSupportResolver.resolve(
            editorDotDirectory: item.editorDotDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let id = item.extensionId
        let idLower = id.lowercased()

        for support in supports {
            let globalRoot = support
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
            if let match = childDirectory(namedLike: id, under: globalRoot, fileManager: fileManager) {
                urls.append(match)
            }

            let workspaceRoot = support
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("workspaceStorage", isDirectory: true)
            if let hashes = try? fileManager.contentsOfDirectory(
                at: workspaceRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for hashDir in hashes {
                    let values = try? hashDir.resourceValues(forKeys: [.isDirectoryKey])
                    guard values?.isDirectory == true else { continue }
                    if let match = childDirectory(namedLike: id, under: hashDir, fileManager: fileManager) {
                        urls.append(match)
                    }
                }
            }

            let vsixRoot = support.appendingPathComponent("CachedExtensionVSIXs", isDirectory: true)
            if let vsixChildren = try? fileManager.contentsOfDirectory(
                at: vsixRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for child in vsixChildren {
                    let name = child.lastPathComponent
                    if name.lowercased().hasPrefix(idLower + "-") || name.lowercased() == idLower {
                        urls.append(child)
                    }
                }
            }
        }

        urls.append(contentsOf: VSCodeExtensionHomePathRules.existingPaths(
            extensionId: id,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ))

        // Deduplicate by standardized path.
        var seen = Set<String>()
        return urls.filter { url in
            let key = (url.path as NSString).standardizingPath
            return seen.insert(key).inserted
        }
    }

    /// Infers extensionId from a related-path shape, then applies the typed check.
    static func isSafeRelatedPath(_ path: String, homeDirectoryPath: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = (homeDirectoryPath as NSString).standardizingPath
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(prefix) else { return false }
        let relative = String(normalized.dropFirst(prefix.count))
        let parts = relative.split(separator: "/").map(String.init)

        // Home personalization: require a concrete extensionId association.
        // Path-only CleaningEngine checks cannot safely infer id from `~/.foo`,
        // so those deletions go through the typed API / UI selection only —
        // except we still accept App Support shapes below.
        if VSCodeExtensionHomePathRules.isHomePersonalizationPath(
            URL(fileURLWithPath: normalized),
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true)
        ) {
            return false
        }

        guard parts.count >= 4,
              parts[0] == "Library",
              parts[1] == "Application Support"
        else {
            return false
        }
        let extensionId: String?
        if parts.count >= 6, parts[3] == "User", parts[4] == "globalStorage" {
            extensionId = parts[5]
        } else if parts.count >= 7, parts[3] == "User", parts[4] == "workspaceStorage" {
            extensionId = parts[6]
        } else if parts.count >= 5, parts[3] == "CachedExtensionVSIXs" {
            extensionId = vsixExtensionId(fromFileName: parts[4])
        } else {
            extensionId = nil
        }
        guard let extensionId, !extensionId.isEmpty else { return false }
        return isSafeRelatedPath(normalized, extensionId: extensionId, homeDirectoryPath: home)
    }

    private static func vsixExtensionId(fromFileName name: String) -> String? {
        // publisher.name-1.2.3[-platform] → publisher.name
        guard let match = name.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9\-]*\.[A-Za-z0-9][A-Za-z0-9\-_.]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(name[match])
    }

    /// Safety gate for related leftovers (not the install dir — that uses
    /// `VSCodeExtensionScanner.isSafeDeletePath`).
    static func isSafeRelatedPath(
        _ path: String,
        extensionId: String,
        homeDirectoryPath: String
    ) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = (homeDirectoryPath as NSString).standardizingPath
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard normalized.hasPrefix(prefix) else { return false }

        if VSCodeExtensionHomePathRules.isAssociated(
            path: normalized,
            extensionId: extensionId,
            homeDirectoryPath: home
        ) {
            return true
        }

        let relative = String(normalized.dropFirst(prefix.count))
        let parts = relative.split(separator: "/").map(String.init)
        // Library/Application Support/<Editor>/...
        guard parts.count >= 4,
              parts[0] == "Library",
              parts[1] == "Application Support"
        else {
            return false
        }

        let idLower = extensionId.lowercased()
        // .../User/globalStorage/<id>
        if parts.count >= 5,
           parts[3] == "User",
           parts[4] == "globalStorage",
           parts.count >= 6,
           parts[5].lowercased() == idLower
        {
            return true
        }
        // .../User/workspaceStorage/<hash>/<id>
        if parts.count >= 7,
           parts[3] == "User",
           parts[4] == "workspaceStorage",
           parts[6].lowercased() == idLower
        {
            return true
        }
        // .../CachedExtensionVSIXs/<id>-*
        if parts.count >= 4,
           parts[3] == "CachedExtensionVSIXs",
           parts.count >= 5
        {
            let name = parts[4].lowercased()
            return name == idLower || name.hasPrefix(idLower + "-")
        }
        return false
    }

    private static func childDirectory(
        namedLike extensionId: String,
        under parent: URL,
        fileManager: FileManager
    ) -> URL? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let wanted = extensionId.lowercased()
        guard let children = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return children.first { child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true && child.lastPathComponent.lowercased() == wanted
        }
    }
}
