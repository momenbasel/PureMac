import Darwin
import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    private let deletionPolicy: SecureDeletionPolicy
    private let secureDeleter: SecureFileDeleter
    private let privilegedClient: PrivilegedCleaningClient
    private let binaryThinner = BinaryThinner()

    init(privilegedClient: PrivilegedCleaningClient = PrivilegedCleaningClient()) {
        let policy = SecureDeletionPolicy(
            userID: getuid(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        deletionPolicy = policy
        secureDeleter = SecureFileDeleter(policy: policy)
        self.privilegedClient = privilegedClient
    }

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        // Paths whose identity lookup was explicitly denied during the
        // unprivileged pass. Only these are eligible for an FDA retry; helper
        // failures and policy rejections must not be mislabeled as TCC issues.
        var fullDiskAccessPaths: Set<String> = []
        // Items that the descriptor-based user-level pass refused with EACCES
        // or EPERM. These need an authorized root-helper second pass.
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
        let logger = await Logger.shared
        do {
            try await FilesystemMutationCoordinator.shared.acquire()
        } catch {
            var result = CleaningResult()
            result.errors.append(error.localizedDescription)
            logger.log(
                "Cleaning blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                level: .error
            )
            return result
        }
        let result = await cleanItemsHoldingMutationLease(
            items,
            logger: logger,
            progressHandler: progressHandler
        )
        await FilesystemMutationCoordinator.shared.release()
        return result
    }

    private func cleanItemsHoldingMutationLease(
        _ items: [CleanableItem],
        logger: Logger,
        progressHandler: @Sendable (Double) -> Void
    ) async -> CleaningResult {
        var result = CleaningResult()
        let total = items.count

        do {
            try await privilegedClient.ensureFilesystemIsReconciled()
        } catch {
            let detail = error.localizedDescription
            result.errors.append(detail)
            logger.log("Cleaning blocked by unresolved privileged deletion: \(detail)", level: .error)
            return result
        }

        for (index, item) in items.enumerated() {
            let progress = Double(index + 1) / Double(total)
            progressHandler(progress)

            if item.category == .purgeableSpace {
                let purged = purgePurgeableSpaceHoldingMutationLease(logger: logger)
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
                let thinOutcome = await thinUniversalBinaryItem(item, logger: logger)
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
                let lprojOutcome = await removeLanguageFileItem(item, logger: logger)
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
                let pruneOutcome = await pruneDockerSystem(logger: logger)
                result.freedSpace += pruneOutcome.freed
                if pruneOutcome.freed > 0 { result.itemsCleaned += 1 }
                result.cleanedPaths.insert(item.path)
                if let error = pruneOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            do {
                let identity: FileIdentity
                if let scannedIdentity = item.fileIdentity {
                    identity = scannedIdentity
                } else {
                    // Synthetic scan rows (for example APFS purgeable space)
                    // have no filesystem object. Real rows must carry the lstat
                    // snapshot made when the row was created.
                    switch FileIdentity.lookup(path: item.path) {
                    case .missing:
                        result.cleanedPaths.insert(item.path)
                        continue
                    case .found:
                        throw SecureDeletionError.identityChanged(item.path)
                    case let .failed(code):
                        throw SecureDeletionError.posix(
                            operation: "lstat",
                            path: item.path,
                            code: code
                        )
                    }
                }

                let request = PrivilegedDeletionRequest(
                    path: item.path,
                    identity: identity,
                    operation: item.category == .largeFiles ? .largeFile : .cleaner
                )
                try secureDeleter.remove(request)
                result.freedSpace += item.size
                result.itemsCleaned += 1
                result.cleanedPaths.insert(item.path)
            } catch {
                let nsError = error as NSError
                let isPermissionDenied =
                    ({
                        if case let SecureDeletionError.posix(_, _, code) = error {
                            return code == EACCES || code == EPERM
                        }
                        return false
                    }()) ||
                    (nsError.domain == NSCocoaErrorDomain &&
                        (nsError.code == NSFileWriteNoPermissionError ||
                         nsError.code == NSFileReadNoPermissionError)) ||
                    (nsError.domain == NSPOSIXErrorDomain &&
                        (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
                if isPermissionDenied {
                    if item.fileIdentity == nil {
                        // Never ask root to delete an object whose scan identity
                        // we could not capture. Keep it visible so the normal
                        // survivor path can offer Full Disk Access instead.
                        let detail = "Could not verify \(item.name) at \(item.path): \(error.localizedDescription)"
                        result.errors.append(detail)
                        result.fullDiskAccessPaths.insert(item.path)
                        logger.log("Identity lookup denied: \(item.path)", level: .warning)
                    } else if FileProtection.isProtectedFromDeletion(path: item.path) {
                        // SIP-protected/immutable entries fail even as root, so
                        // escalating them only wastes an authorization prompt.
                        result.protectedPaths.insert(item.path)
                        logger.log("Skipping SIP-protected path: \(item.path)", level: .info)
                    } else {
                        // Defer to the admin pass — these are typically root-owned
                        // system caches that the user-level process can't unlink.
                        result.requiresAdmin.append(item)
                        logger.log("Deferring to admin pass: \(item.path)", level: .info)
                    }
                } else if case SecureDeletionError.topLevelMissing = error {
                    // Only the initial top-level lstat may report an item as
                    // already gone. Nested ENOENT races are handled inside the
                    // walker and never count the whole request as cleaned.
                    result.cleanedPaths.insert(item.path)
                } else {
                    let detail = "\(item.name) at \(item.path): \(error.localizedDescription)"
                    result.errors.append(detail)
                    logger.log("Clean failed: \(detail)", level: .error)
                }
            }
        }

        return result
    }

    /// Used by uninstall's direct-to-Trash path, which bypasses `cleanItems`
    /// for user-owned objects. It must observe the same write-ahead operation
    /// fence before treating ENOENT as a successfully removed row.
    func ensurePrivilegedDeletionsAreSettled() async throws {
        try await privilegedClient.ensureFilesystemIsReconciled()
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let selectedItems = result.items.filter { $0.isSelected }
        return await cleanItems(selectedItems, progressHandler: progressHandler)
    }

    /// Re-runs the deletion through a root LaunchDaemon registered by
    /// SMAppService. Requests travel as immutable XPC messages and include the
    /// identity captured by the scanner. The helper independently validates
    /// policy, owner, type and identity before descriptor-based unlinkat calls.
    func cleanWithAdminPrivileges(items: [CleanableItem]) async -> CleaningResult {
        let logger = await Logger.shared
        do {
            try await FilesystemMutationCoordinator.shared.acquire()
        } catch {
            var result = CleaningResult()
            result.errors.append(error.localizedDescription)
            logger.log(
                "Administrator cleaning blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                level: .error
            )
            return result
        }
        let result = await cleanWithAdminPrivilegesHoldingMutationLease(
            items: items,
            logger: logger
        )
        await FilesystemMutationCoordinator.shared.release()
        return result
    }

    private func cleanWithAdminPrivilegesHoldingMutationLease(
        items: [CleanableItem],
        logger: Logger
    ) async -> CleaningResult {
        var result = CleaningResult()

        logger.log("Admin pass starting with \(items.count) item(s)", level: .info)

        let validated: [(item: CleanableItem, request: PrivilegedDeletionRequest)] = items.compactMap { item in
            guard !CleaningCategory.appModifying.contains(item.category) else {
                logger.log("Refusing admin deletion for app-modifying item: \(item.path)", level: .warning)
                result.errors.append("Refused administrator deletion for app-modifying item: \(item.path)")
                return nil
            }
            if FileProtection.isProtectedFromDeletion(path: item.path) {
                result.protectedPaths.insert(item.path)
                logger.log("Skipping SIP-protected admin path: \(item.path)", level: .info)
                return nil
            }
            guard let identity = item.fileIdentity else {
                logger.log("Refusing admin escalation without scan identity: \(item.path)", level: .warning)
                result.errors.append("\(item.name) changed or disappeared before administrator authorization")
                return nil
            }

            let operations: [PrivilegedDeletionOperation]
            if item.category == .largeFiles {
                operations = [.largeFile]
            } else {
                // App-uninstall rows currently use .systemJunk. Try the normal
                // cleaner policy first, then the deliberately narrower
                // uninstall policy for bundles/receipts/launch plists.
                operations = [.cleaner, .uninstall]
            }

            for operation in operations {
                let request = PrivilegedDeletionRequest(
                    path: item.path,
                    identity: identity,
                    operation: operation
                )
                if (try? deletionPolicy.validate(request)) != nil {
                    return (item, request)
                }
            }

            logger.log("Refusing admin escalation for unsafe path: \(item.path)", level: .warning)
            result.errors.append("Refused unsafe administrator deletion: \(item.path)")
            return nil
        }
        guard !validated.isEmpty else {
            logger.log("Admin pass: no items survived validation", level: .warning)
            return result
        }

        let responses: [PrivilegedDeletionResponse]
        do {
            responses = try await privilegedClient.deleteItems(validated.map(\.request))
        } catch {
            logger.log("Privileged helper failed: \(error.localizedDescription)", level: .error)
            result.errors.append(error.localizedDescription)
            return result
        }

        guard responses.count == validated.count else {
            result.errors.append("Privileged helper returned an incomplete response")
            logger.log("Admin pass returned \(responses.count) response(s) for \(validated.count) request(s)", level: .error)
            return result
        }

        for ((item, request), response) in zip(validated, responses) {
            guard response.requestID == request.id, response.path == request.path else {
                result.errors.append("Privileged helper returned a response for the wrong item")
                continue
            }
            switch response.status {
            case .deleted:
                result.cleanedPaths.insert(item.path)
                result.itemsCleaned += 1
                result.freedSpace += item.size
            case .missing:
                // The item was already gone before the helper's initial
                // descriptor lookup. Treat the UI row as handled, but do not
                // claim bytes or a deletion that this run did not perform.
                result.cleanedPaths.insert(item.path)
            case .failed where FileProtection.isProtectedFromDeletion(path: request.path):
                result.protectedPaths.insert(item.path)
                logger.log("Admin pass skipped SIP-protected path: \(item.path)", level: .info)
            case .rejected, .failed, .unknown:
                let detail = response.message ?? "\(item.name) at \(item.path) survived administrator removal"
                result.errors.append(detail)
                logger.log("Admin pass survivor: \(detail)", level: .error)
            }
        }
        logger.log(
            "Admin pass complete: \(result.itemsCleaned) deleted, \(result.errors.count) survived, \(result.skippedProtected) protected",
            level: .info
        )
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
    private func pruneDockerSystem(logger: Logger) async -> (freed: Int64, error: String?) {
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
            logger.log("docker system prune failed to launch: \(error.localizedDescription)", level: .error)
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
            logger.log("docker system prune exited \(task.terminationStatus): \(stderrText)", level: .error)
            return (0, "docker system prune failed (exit \(task.terminationStatus))")
        }

        // Final line reads "Total reclaimed space: 1.234GB" ("0B" when idle).
        let output = String(data: outData, encoding: .utf8) ?? ""
        if let line = output.split(separator: "\n").last(where: { $0.contains("Total reclaimed space:") }),
           let raw = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           let bytes = parseDockerBytes(raw) {
            logger.log("docker system prune reclaimed \(bytes) bytes", level: .info)
            return (bytes, nil)
        }
        return (0, nil)
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
        let logger = await Logger.shared
        do {
            try await FilesystemMutationCoordinator.shared.acquire()
        } catch {
            logger.log(
                "Purgeable-space cleanup blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                level: .error
            )
            return 0
        }
        let result = purgePurgeableSpaceHoldingMutationLease(logger: logger)
        await FilesystemMutationCoordinator.shared.release()
        return result
    }

    private func purgePurgeableSpaceHoldingMutationLease(logger: Logger) -> Int64 {
        // Get current purgeable space first
        let beforeFree = getCurrentFreeSpace(logger: logger)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "purgePurgeable", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let afterFree = getCurrentFreeSpace(logger: logger)
            let freedSpace = afterFree - beforeFree
            return max(0, freedSpace)
        } catch {
            logger.log("diskutil purge failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    // MARK: - Trash

    func emptyTrash() async -> Int64 {
        let logger = await Logger.shared
        do {
            try await FilesystemMutationCoordinator.shared.acquire()
        } catch {
            logger.log(
                "Trash cleanup blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                level: .error
            )
            return 0
        }
        do {
            try await privilegedClient.ensureFilesystemIsReconciled()
        } catch {
            await FilesystemMutationCoordinator.shared.release()
            logger.log(
                "Trash cleanup blocked by unresolved privileged deletion: \(error.localizedDescription)",
                level: .error
            )
            return 0
        }
        let result = emptyTrashHoldingMutationLease(logger: logger)
        await FilesystemMutationCoordinator.shared.release()
        return result
    }

    private func emptyTrashHoldingMutationLease(logger: Logger) -> Int64 {
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
            logger.log("Trash cleanup incomplete: \(error.localizedDescription)", level: .warning)
        }

        return totalFreed
    }

    // MARK: - Helpers

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
    private func thinUniversalBinaryItem(
        _ item: CleanableItem,
        logger: Logger
    ) async -> (freed: Int64, cleaned: Bool, error: String?) {
        guard let resolved = validatedAppModificationPath(item) else {
            let msg = "Skipped changed or symlinked app bundle: \(item.path)"
            logger.log(msg, level: .warning)
            return (0, false, msg)
        }
        guard isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "/Applications")
            || isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "\(fileManager.homeDirectoryForCurrentUser.path)/Applications") else {
            let msg = "Skipped unsafe path for thinning: \(item.path) -> \(resolved)"
            logger.log(msg, level: .warning)
            return (0, false, msg)
        }

        guard let finding = UniversalBinaryScanner().finding(forAppAt: resolved) else {
            // Nothing fat left — the app was thinned or replaced since the
            // scan. Count it handled so it doesn't surface as a failure.
            logger.log("No removable slices left in \(item.path); marking handled", level: .info)
            return (0, true, nil)
        }

        switch await binaryThinner.thin(finding) {
        case .success(let freed):
            return (freed, true, nil)
        case .failure(let error):
            if case BinaryThinner.ThinningError.needsAdmin = error {
                let msg = "\(item.name): needs administrator access to thin; skipped"
                logger.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't thin \(item.name): \(error.localizedDescription)"
            logger.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// Routes one .languageFiles item (path = .lproj folder) through
    /// BinaryThinner's staged clone / re-sign / verify / swap flow. The
    /// folder is validated against the same .lproj predicate as before,
    /// then removed from a staged copy of the bundle so the signature seal
    /// stays consistent with the bundle's contents.
    private func removeLanguageFileItem(
        _ item: CleanableItem,
        logger: Logger
    ) async -> (freed: Int64, cleaned: Bool, error: String?) {
        guard let resolved = validatedAppModificationPath(item) else {
            let msg = "Skipped changed or symlinked localization: \(item.path)"
            logger.log(msg, level: .warning)
            return (0, false, msg)
        }
        let normalized = (resolved as NSString).standardizingPath
        guard isRemovableLprojPath(normalized) else {
            let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
            logger.log(msg, level: .warning)
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
                logger.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't remove localization \(item.name): \(error.localizedDescription)"
            logger.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// App-bundle rewriting uses BinaryThinner's staged copy/swap flow rather
    /// than the deletion helper. Reject symlinked paths and non-directories at
    /// each step; a successful swap intentionally changes descendant inodes,
    /// so later selected localizations from the same app remain valid.
    private func validatedAppModificationPath(_ item: CleanableItem) -> String? {
        guard let canonical = try? deletionPolicy.canonicalPath(item.path)
        else {
            return nil
        }

        let resolved = (URL(fileURLWithPath: canonical).resolvingSymlinksInPath().path as NSString)
            .standardizingPath
        guard resolved == canonical else { return nil }

        guard case let .found(current) = FileIdentity.lookup(path: canonical),
              current.isDirectory
        else {
            return nil
        }
        return canonical
    }

    private func isAppBundlePath(_ path: String, rootedAt root: String) -> Bool {
        guard isInside(path, root: root) else { return false }
        let normalizedRoot = (root as NSString).standardizingPath
        guard path != normalizedRoot else { return false }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        let relative = String(path.dropFirst(rootWithSeparator.count))
        let components = relative.split(separator: "/").map(String.init)
        guard let bundleName = components.last,
              bundleName.lowercased().hasSuffix(".app")
        else {
            return false
        }
        return !components.dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }

    private func isInside(_ path: String, root: String) -> Bool {
        let normalizedRoot = (root as NSString).standardizingPath
        if path == normalizedRoot { return true }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return path.hasPrefix(rootWithSeparator)
    }

    private func getCurrentFreeSpace(logger: Logger) -> Int64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            logger.log("Cannot read filesystem attributes: \(error.localizedDescription)", level: .warning)
            return 0
        }
    }
}
