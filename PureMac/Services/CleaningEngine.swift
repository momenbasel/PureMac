import Darwin
import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    private let deletionPolicy: SecureDeletionPolicy
    private let secureDeleter: SecureFileDeleter
    private let privilegedClient: PrivilegedCleaningClient

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
            case .rejected, .failed, .unknown:
                let detail = response.message ?? "\(item.name) at \(item.path) survived administrator removal"
                result.errors.append(detail)
                logger.log("Admin pass survivor: \(detail)", level: .error)
            }
        }
        logger.log("Admin pass complete: \(result.itemsCleaned) deleted, \(result.errors.count) survived", level: .info)
        return result
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
