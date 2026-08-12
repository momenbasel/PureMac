import Foundation

enum VSCodeExtensionsIndexPruner {
    /// Best-effort: drop entries from `extensions.json` whose install folder was removed.
    static func pruneIndexes(afterRemoving paths: [URL], fileManager: FileManager = .default) {
        let removedFolders = Set(paths.map { ($0.path as NSString).standardizingPath })
        guard !removedFolders.isEmpty else { return }

        var indexDirs = Set<URL>()
        for path in removedFolders {
            let url = URL(fileURLWithPath: path)
            // .../extensions/<folder> → .../extensions
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "extensions" {
                indexDirs.insert(parent)
            }
        }

        for dir in indexDirs {
            let indexURL = dir.appendingPathComponent("extensions.json")
            guard fileManager.fileExists(atPath: indexURL.path),
                  let data = try? Data(contentsOf: indexURL),
                  var list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                continue
            }
            let before = list.count
            list.removeAll { entry in
                let relative = (entry["relativeLocation"] as? String)
                    ?? (entry["location"] as? [String: Any])?["path"] as? String
                guard let relative, !relative.isEmpty else { return false }
                let absolute = (dir.appendingPathComponent(relative).path as NSString).standardizingPath
                return removedFolders.contains(absolute)
            }
            guard list.count != before,
                  let out = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
            else {
                continue
            }
            try? out.write(to: indexURL, options: .atomic)
        }
    }
}
