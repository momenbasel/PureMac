import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    private let binaryThinner = BinaryThinner()

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        // Items that user-level FileManager.removeItem refused with EACCES /
        // EPERM. These are root-owned and need an admin-privileged second
        // pass via cleanWithAdminPrivileges(items:).
        var requiresAdmin: [CleanableItem] = []
        // Paths skipped because they are SIP-protected or immutable (see
        // FileProtection). Deleting these fails even as root, so they are
        // recorded here — not in errors — and must never trigger the
        // "Couldn't clean everything" alert.
        var protectedPaths: Set<String> = []
        var skippedProtected: Int { protectedPaths.count }
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
                // Purgeable space is a one-shot reclaim action, not a file
                // unlink. Mark it handled so it isn't later mistaken for an
                // item that "couldn't be removed" (the purge ran regardless of
                // how much APFS chose to release). See issue #112.
                result.cleanedPaths.insert(item.path)
                continue
            }

            if item.category == .universalBinaries {
                // Thinning is a lipo rewrite plus re-sign, not a file unlink,
                // so it bypasses the delete path entirely. The item path is
                // the app bundle; the per-binary work list is re-derived here
                // so a stale scan can't strip slices that no longer exist.
                let thinOutcome = await thinUniversalBinaryItem(item)
                result.freedSpace += thinOutcome.freed
                if thinOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = thinOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if item.category == .languageFiles {
                // Localizations are sealed into the bundle's CodeResources; a
                // plain unlink would break the app's code signature, so the
                // folder is removed through BinaryThinner's staged re-sign
                // flow instead of the delete path.
                let lprojOutcome = await removeLanguageFileItem(item)
                result.freedSpace += lprojOutcome.freed
                if lprojOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = lprojOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if item.category == .dockerCache && item.path.isEmpty {
                // The virtual "Docker prune" entry (empty path, like
                // purgeableSpace) reclaims space inside the Docker/OrbStack VM
                // via `docker system prune -f` — there is no file to unlink.
                let pruneOutcome = await pruneDockerSystem()
                result.freedSpace += pruneOutcome.freed
                if pruneOutcome.freed > 0 { result.itemsCleaned += 1 }
                result.cleanedPaths.insert(item.path)
                if let error = pruneOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if let runtimeID = item.simctlRuntimeIdentifier {
                // Simulator runtimes live in CoreSimulator's secure storage;
                // deleting the mount path by hand leaves orphaned disk images.
                // Always go through `xcrun simctl runtime delete`.
                let deleteOutcome = await deleteSimulatorRuntime(identifier: runtimeID, reportedSize: item.size)
                result.freedSpace += deleteOutcome.freed
                if deleteOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = deleteOutcome.error {
                    result.errors.append(error)
                }
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
                    // languageFiles never reaches here — it is handled above
                    // via the staged re-sign flow, not the delete path.
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
                    // SIP-protected/immutable entries fail even as root, so
                    // escalating them just wastes an auth prompt and produces
                    // a bogus "survived admin removal" error. Record and move on.
                    if FileProtection.isProtectedFromDeletion(path: item.path) {
                        result.protectedPaths.insert(item.path)
                        Logger.shared.log("Skipping SIP-protected path: \(item.path)", level: .info)
                        continue
                    }
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
                // languageFiles is deliberately absent: an admin rm -rf of an
                // .lproj would break the bundle's signature seal with no
                // re-sign, so those items never escalate — they only go
                // through the staged BinaryThinner flow in cleanItems.
                return isSafeToDelete(resolvedPath: resolved) || isSafeUninstallEscalationPath(resolved)
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

        // Live daemon logs (e.g. /private/var/log/wifi.log) are recreated by
        // their writer the instant root rm unlinks them. A bare re-stat then
        // misreads the fresh file as "survived admin removal" and raises a
        // bogus "Couldn't clean everything" alert. Capture each path's inode
        // before the delete so the survivor check can tell a recreated file
        // from an untouched one.
        var preDeleteInodes: [String: UInt64] = [:]
        for (_, resolved) in validated {
            if let attrs = try? fileManager.attributesOfItem(atPath: resolved),
               let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value {
                preDeleteInodes[resolved] = inode
            }
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-rm-\(UUID().uuidString)")
        do {
            try payload.write(to: tempFile, options: [.atomic])
        } catch {
            Logger.shared.log("Couldn't stage admin path list: \(error.localizedDescription)", level: .error)
            return result
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let quotedTempPath = shellSingleQuoted(tempFile.path)
        let script = """
        do shell script "/usr/bin/xargs -0 /bin/rm -rf -- < \(quotedTempPath)" with administrator privileges
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
            } else if FileProtection.isProtectedFromDeletion(path: resolved) {
                // SIP-protected survivors are expected — root rm can't touch
                // them either. Record quietly instead of raising an error.
                result.protectedPaths.insert(item.path)
                Logger.shared.log("Admin pass skipped SIP-protected path: \(item.path)", level: .info)
            } else if let preInode = preDeleteInodes[resolved],
                      let nowInode = ((try? fileManager.attributesOfItem(atPath: resolved))?[.systemFileNumber] as? NSNumber)?.uint64Value,
                      nowInode != preInode {
                // Different inode: the original WAS deleted and the owning
                // daemon immediately recreated the file. The old bytes are
                // gone, so count it as cleaned rather than a survivor.
                result.cleanedPaths.insert(item.path)
                result.itemsCleaned += 1
                result.freedSpace += item.size
                Logger.shared.log("Deleted and recreated by its daemon (live log): \(item.path)", level: .info)
            } else {
                let detail = "\(item.name) at \(item.path) survived admin removal"
                result.errors.append(detail)
                Logger.shared.log("Admin pass survivor: \(detail)", level: .error)
            }
        }
        Logger.shared.log("Admin pass complete: \(result.itemsCleaned) deleted, \(result.errors.count) survived, \(result.skippedProtected) protected", level: .info)
        return result
    }

    // MARK: - Docker

    /// Runs `docker system prune -f` (no -a: tagged images and running
    /// containers survive) and reports the bytes Docker says it reclaimed.
    /// This is the clean action behind the virtual "Docker prune" item —
    /// with a VM-based runtime (Docker Desktop, OrbStack) the junk lives
    /// inside the VM disk, unreachable by any file unlink from the host.
    /// Returns a friendly error when no CLI is installed or the daemon is
    /// not running — common with OrbStack, which only runs on demand.
    func pruneDockerSystem() async -> (freed: Int64, error: String?) {
        let dockerBinPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        guard let dockerBin = dockerBinPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return (0, "Docker CLI not found — install Docker Desktop or OrbStack")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: dockerBin)
        task.arguments = ["system", "prune", "-f"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        do {
            try task.run()
        } catch {
            Logger.shared.log("docker system prune failed to launch: \(error.localizedDescription)", level: .error)
            return (0, "Couldn't run docker system prune: \(error.localizedDescription)")
        }
        // Drain both pipes BEFORE waiting: prune lists every deleted object
        // and can overflow the 64 KB pipe buffer, deadlocking waitUntilExit.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            if stderrText.contains("Cannot connect") || stderrText.contains("dial unix")
                || stderrText.contains("daemon") {
                return (0, "Docker isn't running — start Docker Desktop or OrbStack, then clean again")
            }
            Logger.shared.log("docker system prune exited \(task.terminationStatus): \(stderrText)", level: .error)
            return (0, "docker system prune failed (exit \(task.terminationStatus))")
        }

        // Final line reads "Total reclaimed space: 1.234GB" ("0B" when idle).
        let output = String(data: outData, encoding: .utf8) ?? ""
        if let line = output.split(separator: "\n").last(where: { $0.contains("Total reclaimed space:") }),
           let raw = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           let bytes = parseDockerBytes(raw) {
            Logger.shared.log("docker system prune reclaimed \(bytes) bytes", level: .info)
            return (bytes, nil)
        }
        return (0, nil)
    }

    // MARK: - Simulator Runtimes

    /// Deletes one simulator runtime disk image via
    /// `xcrun simctl runtime delete <identifier>`. Uses the scan-time size as
    /// the freed estimate — simctl does not print reclaimable bytes.
    /// When `xcrun` is missing, returns a clear error and does not attempt
    /// a Process launch (avoids a cryptic "No such file" failure).
    func deleteSimulatorRuntime(identifier: String, reportedSize: Int64) async -> (freed: Int64, cleaned: Bool, error: String?) {
        guard SimulatorRuntimeSupport.isXcrunAvailable() else {
            return (0, false, SimulatorRuntimeSupport.missingXcrunMessage)
        }

        let result = SimulatorRuntimeSupport.runXcrun(["simctl", "runtime", "delete", identifier])
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if detail == SimulatorRuntimeSupport.missingXcrunMessage {
                return (0, false, SimulatorRuntimeSupport.missingXcrunMessage)
            }
            if detail.localizedCaseInsensitiveContains("CoreSimulator")
                || detail.localizedCaseInsensitiveContains("simdiskimaged") {
                return (0, false, "Simulator services unavailable — open Xcode once, then try again")
            }
            Logger.shared.log("simctl runtime delete \(identifier) exited \(result.status): \(detail)", level: .error)
            return (0, false, "Couldn't delete simulator runtime \(identifier)")
        }

        Logger.shared.log("Deleted simulator runtime \(identifier) (~\(reportedSize) bytes)", level: .info)
        return (reportedSize, true, nil)
    }

    /// Parse Docker's compact size format ("1.23GB", "456MB", "789kB", "0B").
    private func parseDockerBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        for (suffix, multiplier) in units {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let value = Double(numberPart) {
                    return Int64(value * multiplier)
                }
            }
        }
        return nil
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
        // Cloud File Provider state is never deletable, whatever category asked
        // and whichever allowed root it happens to sit under (issue #142).
        // Checked before the allowlist because several provider directories live
        // inside ~/Library/Caches and ~/Library/Application Support, which are
        // themselves allowed roots.
        if ProviderPaths.isProviderOwned(resolvedPath) {
            Logger.shared.log(
                "Refusing to delete cloud provider state: \(resolvedPath)",
                level: .warning
            )
            return false
        }

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
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            "\(home)/Library/Developer/XCTestDevices",
            "\(home)/Library/Developer/Xcode/UserData/Previews",
            "\(home)/Library/org.swift.swiftpm",
            "\(home)/.Trash",
            "\(home)/.npm",
            "\(home)/.cache",
            "\(home)/Library/Containers/com.docker.docker",
            // Docker/OrbStack cache + log roots surfaced by scanDockerCache.
            // Without these the items scan fine but every delete is refused
            // as "unsafe path" — the category looked broken. Narrow roots
            // only; ~/.docker itself holds config.json and TLS certs, and
            // ~/.orbstack/data is the VM disk, so neither is allow-listed.
            "\(home)/.docker/cli-plugins/.cache",
            "\(home)/.docker/buildx/cache",
            "\(home)/.orbstack/log",
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

    /// A removable localization folder inside an installed app bundle:
    /// /Applications/.../<App>.app/Contents/Resources/<lang>.lproj (or the
    /// same shape under ~/Applications), where <lang> is neither in the
    /// scanner's keep-set (user-preferred languages plus en/English/Base)
    /// nor the bundle's development region. Everything else — including any
    /// other path inside an app bundle — stays blocked.
    private func isRemovableLprojPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        guard (normalized as NSString).pathExtension.lowercased() == "lproj" else { return false }

        let home = fileManager.homeDirectoryForCurrentUser.path
        guard isInside(normalized, root: "/Applications") || isInside(normalized, root: "\(home)/Applications") else {
            return false
        }

        // Must sit exactly at <bundle>.app/Contents/Resources/<lang>.lproj.
        let resources = (normalized as NSString).deletingLastPathComponent
        let contents = (resources as NSString).deletingLastPathComponent
        let bundle = (contents as NSString).deletingLastPathComponent
        guard (resources as NSString).lastPathComponent == "Resources",
              (contents as NSString).lastPathComponent == "Contents",
              (bundle as NSString).lastPathComponent.lowercased().hasSuffix(".app") else {
            return false
        }

        let language = ((normalized as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        // Same keep-set as the scanner (user-preferred languages plus the
        // en/English/Base fallbacks), so a stale or replayed item list can
        // never delete a localization the user's current settings depend on.
        if LanguageFilesScanner().keepLanguages.contains(language) { return false }
        // The bundle's development region is its last-resort fallback
        // localization — often the only complete one. Deleting it leaves
        // NSLocalizedString returning raw keys or breaks nib loading.
        if let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
           let region = plist["CFBundleDevelopmentRegion"] as? String {
            let normalizedRegion = region.lowercased().replacingOccurrences(of: "_", with: "-")
            if language == normalizedRegion { return false }
            if let base = normalizedRegion.split(separator: "-").first, language == String(base) {
                return false
            }
        }
        return true
    }

    /// Runs BinaryThinner for one .universalBinaries item (path = app
    /// bundle). Re-scans the bundle first so the lipo work list reflects the
    /// bundle's current state, not the possibly stale scan result.
    private func thinUniversalBinaryItem(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?) {
        let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
        guard isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "/Applications")
            || isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "\(fileManager.homeDirectoryForCurrentUser.path)/Applications") else {
            let msg = "Skipped unsafe path for thinning: \(item.path) -> \(resolved)"
            Logger.shared.log(msg, level: .warning)
            return (0, false, msg)
        }

        guard let finding = UniversalBinaryScanner().finding(forAppAt: resolved) else {
            // Nothing fat left — the app was thinned or replaced since the
            // scan. Count it handled so it doesn't surface as a failure.
            Logger.shared.log("No removable slices left in \(item.path); marking handled", level: .info)
            return (0, true, nil)
        }

        switch await binaryThinner.thin(finding) {
        case .success(let freed):
            return (freed, true, nil)
        case .failure(let error):
            if case BinaryThinner.ThinningError.needsAdmin = error {
                let msg = "\(item.name): needs administrator access to thin; skipped"
                Logger.shared.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't thin \(item.name): \(error.localizedDescription)"
            Logger.shared.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// Routes one .languageFiles item (path = .lproj folder) through
    /// BinaryThinner's staged clone / re-sign / verify / swap flow. The
    /// folder is validated against the same .lproj predicate as before,
    /// then removed from a staged copy of the bundle so the signature seal
    /// stays consistent with the bundle's contents.
    private func removeLanguageFileItem(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?) {
        let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
        let normalized = (resolved as NSString).standardizingPath
        guard isRemovableLprojPath(normalized) else {
            let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
            Logger.shared.log(msg, level: .warning)
            return (0, false, msg)
        }

        guard fileManager.fileExists(atPath: normalized) else {
            // Already gone (app updated or reinstalled since the scan) —
            // count it handled so it doesn't surface as a failure.
            return (0, true, nil)
        }

        // <lang>.lproj -> Resources -> Contents -> bundle; the shape was
        // just validated by isRemovableLprojPath.
        let bundle = (((normalized as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent as NSString).deletingLastPathComponent

        switch await binaryThinner.removeLproj(at: normalized, fromAppAt: bundle) {
        case .success:
            return (item.size, true, nil)
        case .failure(let error):
            if case BinaryThinner.ThinningError.needsAdmin = error {
                let msg = "\(item.name): needs administrator access to modify the app; skipped"
                Logger.shared.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't remove localization \(item.name): \(error.localizedDescription)"
            Logger.shared.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// Allows the app uninstaller to escalate only the protected roots it owns:
    /// app bundles, package receipts, and launch plists. This intentionally
    /// stays narrower than the normal cleaner allow-list.
    private func isSafeUninstallEscalationPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = fileManager.homeDirectoryForCurrentUser.path

        return isAppBundlePath(normalized, rootedAt: "/Applications")
            || isAppBundlePath(normalized, rootedAt: "\(home)/Applications")
            || isReceiptPath(normalized, rootedAt: "/private/var/db/receipts")
            || isReceiptPath(normalized, rootedAt: "/var/db/receipts")
            || isPlistUnder(normalized, root: "/Library/LaunchDaemons")
            || isPlistUnder(normalized, root: "/Library/LaunchAgents")
    }

    private func isAppBundlePath(_ path: String, rootedAt root: String) -> Bool {
        guard isInside(path, root: root) else { return false }
        let normalizedRoot = (root as NSString).standardizingPath
        guard path != normalizedRoot else { return false }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        let relative = String(path.dropFirst(rootWithSeparator.count))
        return relative.split(separator: "/").contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    private func isReceiptPath(_ path: String, rootedAt root: String) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard parent == (root as NSString).standardizingPath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "plist" || ext == "bom"
    }

    private func isPlistUnder(_ path: String, root: String) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        return parent == (root as NSString).standardizingPath && (path as NSString).pathExtension.lowercased() == "plist"
    }

    private func isInside(_ path: String, root: String) -> Bool {
        let normalizedRoot = (root as NSString).standardizingPath
        if path == normalizedRoot { return true }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return path.hasPrefix(rootWithSeparator)
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
