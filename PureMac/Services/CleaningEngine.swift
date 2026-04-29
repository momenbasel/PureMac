import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        // Items that user-level FileManager.removeItem refused with EACCES /
        // EPERM. These are root-owned and need an admin-privileged second
        // pass via cleanWithAdminPrivileges(items:).
        var requiresAdmin: [CleanableItem] = []
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
                result.cleanedPaths.insert(item.path)
            } catch {
                let nsError = error as NSError
                let isPermissionDenied =
                    (nsError.domain == NSCocoaErrorDomain &&
                        (nsError.code == NSFileWriteNoPermissionError ||
                         nsError.code == NSFileReadNoPermissionError)) ||
                    (nsError.domain == NSPOSIXErrorDomain &&
                        (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
                if isPermissionDenied {
                    // Defer to the admin pass — these are typically root-owned
                    // system caches that the user-level process can't unlink.
                    result.requiresAdmin.append(item)
                    Logger.shared.log("Deferring to admin pass: \(item.path)", level: .info)
                } else {
                    let detail = "\(item.name) at \(item.path): \(error.localizedDescription)"
                    result.errors.append(detail)
                    Logger.shared.log("Clean failed: \(detail)", level: .error)
                }
            }
        }

        return result
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let selectedItems = result.items.filter { $0.isSelected }
        return await cleanItems(selectedItems, progressHandler: progressHandler)
    }

    /// Re-runs the deletion of the supplied items as root via NSAppleScript's
    /// "with administrator privileges" clause. Triggers exactly one auth
    /// prompt for the whole batch (macOS caches the credential for ~5 min).
    ///
    /// Every path is re-validated against the same allow-list as the user-
    /// level pass (isSafeToDelete / isExplicitSingleFileDeletable) before it
    /// gets handed off to /bin/rm. Paths are passed via a NUL-separated
    /// temp file consumed by xargs -0, so no shell-quoting pitfalls.
    func cleanWithAdminPrivileges(items: [CleanableItem]) async -> CleaningResult {
        var result = CleaningResult()

        Logger.shared.log("Admin pass starting with \(items.count) item(s)", level: .info)

        // Re-validate. Don't trust the caller — anything not on the allow-list
        // refuses to escalate.
        let validated: [(item: CleanableItem, resolved: String)] = items.compactMap { item in
            let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            let accepted: Bool = {
                if item.category == .largeFiles {
                    return isExplicitSingleFileDeletable(resolvedPath: resolved)
                }
                return isSafeToDelete(resolvedPath: resolved)
            }()
            if !accepted {
                Logger.shared.log("Refusing admin escalation for unsafe path: \(item.path)", level: .warning)
            }
            return accepted ? (item, resolved) : nil
        }
        guard !validated.isEmpty else {
            Logger.shared.log("Admin pass: no items survived validation", level: .warning)
            return result
        }

        // Stage paths NUL-separated so newlines/spaces in paths don't matter.
        let staged = validated.map(\.resolved).joined(separator: "\u{0}")
        guard let payload = staged.data(using: .utf8) else { return result }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-rm-\(UUID().uuidString)")
        do {
            try payload.write(to: tempFile, options: [.atomic])
        } catch {
            Logger.shared.log("Couldn't stage admin path list: \(error.localizedDescription)", level: .error)
            return result
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // UUIDs are alphanumeric + hyphens, NSTemporaryDirectory is a known
        // path with no shell metacharacters, so direct embedding is safe.
        let script = """
        do shell script "/usr/bin/xargs -0 /bin/rm -rf -- < \(tempFile.path)" with administrator privileges
        """

        let runResult: (success: Bool, error: String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                appleScript?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(returning: (false, "\(errorInfo)"))
                } else {
                    continuation.resume(returning: (true, nil))
                }
            }
        }

        guard runResult.success else {
            // -128 is "user cancelled" — log quietly, no need for an error row.
            if let err = runResult.error, !err.contains("-128") {
                Logger.shared.log("Admin clean failed: \(err)", level: .error)
                result.errors.append("Administrator authorization failed")
            }
            return result
        }

        // Verify which items actually disappeared. xargs may have reported a
        // partial failure even when the AppleScript exited cleanly, so we
        // re-stat every path rather than trust the script's exit status.
        for (item, resolved) in validated {
            if !FileManager.default.fileExists(atPath: resolved) {
                result.cleanedPaths.insert(item.path)
                result.itemsCleaned += 1
                result.freedSpace += item.size
            } else {
                let detail = "\(item.name) at \(item.path) survived admin removal"
                result.errors.append(detail)
                Logger.shared.log("Admin pass survivor: \(detail)", level: .error)
            }
        }
        Logger.shared.log("Admin pass complete: \(result.itemsCleaned) deleted, \(result.errors.count) survived", level: .info)
        return result
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
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/.Trash",
            "\(home)/.npm",
            "\(home)/.cache",
            "\(home)/Library/Containers/com.docker.docker",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "/private/var/tmp",
            // /var is a symlink to /private/var, and resolvingSymlinksInPath
            // gives the /var form. Both spellings must be allow-listed or
            // every system log/tmp deletion silently fails the safety check.
            "/var/log",
            "/var/tmp",
            "/tmp",
        ]
        // Either the path equals an allow-listed root (whole-subtree wipe by
        // the scanner that emits the root itself, e.g. DerivedData) or it
        // sits strictly inside one. The trailing "/" on the prefix match
        // prevents siblings like "/tmpfoo" from sneaking past "/tmp".
        let normalized = (resolvedPath as NSString).standardizingPath
        return allowedRoots.contains { root in
            if normalized == root { return true }
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
