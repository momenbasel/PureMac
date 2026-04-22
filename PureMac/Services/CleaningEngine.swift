import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
    }

    // MARK: - Public API

    func cleanItems(_ items: [CleanableItem], progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        var result = CleaningResult()
        let total = items.count

        for (index, item) in items.enumerated() {
            let progress = Double(index + 1) / Double(total)
            progressHandler(progress)

            if item.category == .purgeableSpace {
                let purged = await purgePurgeableSpace()
                result.freedSpace += purged
                if purged > 0 { result.itemsCleaned += 1 }
                continue
            }

            do {
                let itemURL = URL(fileURLWithPath: item.path)
                guard fileManager.fileExists(atPath: item.path) else { continue }

                // Security: resolve symlinks, validate the real path, delete
                // through the resolved URL. Deleting through the unresolved
                // path lets an attacker-at-same-UID swap a component to a
                // symlink after the check and have us follow it.
                let resolvedURL = itemURL.resolvingSymlinksInPath()
                let resolved = resolvedURL.path

                // Large files surfaced by scanLargeFiles are per-file items
                // under Downloads/Documents/Desktop; those get a narrower check
                // instead of the whole-subtree allow-list.
                let pathAccepted: Bool = {
                    if item.category == .largeFiles {
                        return isExplicitSingleFileDeletable(resolvedPath: resolved)
                    }
                    return isSafeToDelete(resolvedPath: resolved)
                }()
                guard pathAccepted else {
                    let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                // Narrow the TOCTOU window: re-resolve right before the delete
                // and require the resolved path to still match. Any concurrent
                // swap between check and delete aborts the operation.
                let reResolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
                guard reResolved == resolved else {
                    let msg = "Aborting delete: path resolution changed between check and unlink for \(item.path)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                try fileManager.removeItem(at: resolvedURL)
                result.freedSpace += item.size
                result.itemsCleaned += 1
            } catch {
                result.errors.append("\(item.name): \(error.localizedDescription)")
            }
        }

        return result
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let selectedItems = result.items.filter { $0.isSelected }
        return await cleanItems(selectedItems, progressHandler: progressHandler)
    }

    // MARK: - Purgeable Space

    func purgePurgeableSpace() async -> Int64 {
        // Get current purgeable space first
        let beforeFree = getCurrentFreeSpace()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "purgePurgeable", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let afterFree = getCurrentFreeSpace()
            let freedSpace = afterFree - beforeFree
            return max(0, freedSpace)
        } catch {
            Logger.shared.log("diskutil purge failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    // MARK: - Trash

    func emptyTrash() async -> Int64 {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        var totalFreed: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: trashPath)
            for item in contents {
                let fullPath = (trashPath as NSString).appendingPathComponent(item)
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath) {
                    totalFreed += (attrs[.size] as? Int64) ?? 0
                }
                try fileManager.removeItem(atPath: fullPath)
            }
        } catch {
            Logger.shared.log("Trash cleanup incomplete: \(error.localizedDescription)", level: .warning)
        }

        return totalFreed
    }

    // MARK: - Helpers

    /// Validates that a resolved path is safe to delete.
    /// Prevents symlink attacks where a link in ~/Library/Caches points to ~/.ssh.
    /// Downloads, Documents, and Desktop are intentionally NOT whole-subtree
    /// allow-listed - scanLargeFiles emits per-file items instead, so those
    /// deletions can still happen through the explicit per-item flow.
    private func isSafeToDelete(resolvedPath: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let allowedRoots = [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Support",
            "\(home)/Library/Preferences",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Mail Downloads",
            "\(home)/.Trash",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "/private/var/tmp",
            "/tmp",
        ]
        // Allow whole-subtree deletion only; require a trailing "/" on the
        // root match so siblings like "/tmpfoo" cannot pass the prefix check.
        let normalized = (resolvedPath as NSString).standardizingPath
        return allowedRoots.contains { root in
            let rootWithSeparator = root.hasSuffix("/") ? root : root + "/"
            return normalized.hasPrefix(rootWithSeparator)
        }
    }

    /// Allow a single-file delete under Downloads/Documents/Desktop when it
    /// was explicitly surfaced by a scanner (e.g. scanLargeFiles). Whole-subtree
    /// deletion of those roots remains blocked.
    func isExplicitSingleFileDeletable(resolvedPath: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let perFileRoots = [
            "\(home)/Downloads/",
            "\(home)/Documents/",
            "\(home)/Desktop/",
        ]
        let normalized = (resolvedPath as NSString).standardizingPath
        return perFileRoots.contains { normalized.hasPrefix($0) }
    }

    private func getCurrentFreeSpace() -> Int64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            Logger.shared.log("Cannot read filesystem attributes: \(error.localizedDescription)", level: .warning)
            return 0
        }
    }
}
