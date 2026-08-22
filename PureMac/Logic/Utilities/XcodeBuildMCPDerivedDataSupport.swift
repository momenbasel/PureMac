import Foundation
import Darwin

/// Discovery and safety policy for XcodeBuildMCP-managed DerivedData.
///
/// Matches XcodeBuildMCP's own purge contract: active or recent DerivedData is
/// protected from unattended cleanup, and deletions must not run while the
/// workspace filesystem lifecycle lock is held.
/// See https://www.xcodebuildmcp.com/docs/storage-management
enum XcodeBuildMCPDerivedDataSupport {
    static let lifecycleLockDirectoryName = "filesystem-lifecycle.lock"
    static let lifecycleLockOwnerFileName = "owner.json"
    /// Same lease window XcodeBuildMCP uses for filesystem-lifecycle locks.
    static let lifecycleLockLease: TimeInterval = 10 * 60
    /// Scheduled cleanup only considers build data that has been unused for a
    /// full week. Manual cleanup remains available for any discovered item.
    static let scheduledCleanupAge: TimeInterval = 7 * 24 * 60 * 60

    struct LifecycleLock {
        fileprivate let directory: URL
        fileprivate let token: String
    }

    static func canonicalHomeDirectory(_ homeDirectory: URL) -> URL {
        homeDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    static func managedRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        canonicalHomeDirectory(homeDirectory)
            .appendingPathComponent("Library/Developer/XcodeBuildMCP", isDirectory: true)
    }

    static func isManagedDerivedDataPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let root = managedRoot(homeDirectory: homeDirectory).path

        // XcodeBuildMCP before v2.5 used one shared DerivedData directory.
        if normalized == (root as NSString).appendingPathComponent("DerivedData") {
            return true
        }

        let workspacesRoot = (root as NSString).appendingPathComponent("workspaces")
        let prefix = workspacesRoot + "/"
        guard normalized.hasPrefix(prefix) else { return false }

        let relative = String(normalized.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2
            && !components[0].isEmpty
            && components[1] == "DerivedData"
    }

    /// Returns whether a managed DerivedData item may participate in scheduled
    /// cleanup. Ordinary PureMac items remain governed by their selection flag;
    /// XcodeBuildMCP items additionally need to be old and unlocked.
    static func isEligibleForScheduledAutoClean(
        _ item: CleanableItem,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        fileManager: FileManager = .default,
        isProcessAlive: @escaping (Int32) -> Bool = isProcessAlive
    ) -> Bool {
        guard isManagedDerivedDataPath(item.path, homeDirectory: homeDirectory) else {
            return true
        }
        guard let lastModified = item.lastModified,
              now.timeIntervalSince(lastModified) >= scheduledCleanupAge else {
            return false
        }
        return !isLifecycleLockHeld(
            forManagedDerivedDataPath: item.path,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            now: now,
            isProcessAlive: isProcessAlive
        )
    }

    static func workspaceKey(
        forManagedDerivedDataPath path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let normalized = (path as NSString).standardizingPath
        let workspacesRoot = managedRoot(homeDirectory: homeDirectory)
            .appendingPathComponent("workspaces", isDirectory: true)
            .path + "/"
        guard normalized.hasPrefix(workspacesRoot) else { return nil }
        let relative = String(normalized.dropFirst(workspacesRoot.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == "DerivedData", !components[0].isEmpty else {
            return nil
        }
        return String(components[0])
    }

    /// True when XcodeBuildMCP's workspace filesystem lifecycle lock is held
    /// (or cannot be proven free). Legacy shared DerivedData has no per-workspace
    /// lock and always returns false here.
    static func isLifecycleLockHeld(
        forManagedDerivedDataPath path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: Date = Date(),
        isProcessAlive: (Int32) -> Bool = isProcessAlive
    ) -> Bool {
        guard let workspaceKey = workspaceKey(
            forManagedDerivedDataPath: path,
            homeDirectory: homeDirectory
        ) else {
            return false
        }

        let lockDir = managedRoot(homeDirectory: homeDirectory)
            .appendingPathComponent("workspaces/\(workspaceKey)/locks/\(lifecycleLockDirectoryName)", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: lockDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let ownerURL = lockDir.appendingPathComponent(lifecycleLockOwnerFileName)
        if let owner = readLockOwner(at: ownerURL) {
            if owner.expiresAtMs > now.timeIntervalSince1970 * 1000 {
                return true
            }
            if isProcessAlive(Int32(owner.pid)) {
                return true
            }
            // Expired owner whose process is dead — treat as free (matches
            // XcodeBuildMCP's recoverable-stale-lock policy).
            return false
        }

        // No owner.json: if the lock directory is still within the lease window,
        // assume an active holder rather than racing a live build.
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockDir.path),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(modified) <= lifecycleLockLease
    }

    /// Atomically claims a workspace lifecycle lock for a short, local
    /// filesystem operation. `mkdir` is used instead of FileManager's
    /// createDirectory because POSIX mkdir gives us an exclusive EEXIST result
    /// when XcodeBuildMCP (or another PureMac process) wins the race.
    ///
    /// A legacy shared DerivedData path has no workspace lock, so it returns
    /// nil and must not be deleted by a caller that requires coordination.
    static func acquireLifecycleLock(
        forManagedDerivedDataPath path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> LifecycleLock? {
        guard let workspaceKey = workspaceKey(
            forManagedDerivedDataPath: path,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }

        let lockDirectory = managedRoot(homeDirectory: homeDirectory)
            .appendingPathComponent(
                "workspaces/\(workspaceKey)/locks/\(lifecycleLockDirectoryName)",
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(
                at: lockDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        guard Darwin.mkdir(lockDirectory.path, S_IRWXU) == 0 else { return nil }

        let token = UUID().uuidString
        let nowMs = Date().timeIntervalSince1970 * 1000
        let owner: [String: Any] = [
            "token": token,
            "pid": Int(getpid()),
            "purpose": "filesystem-lifecycle",
            "acquiredAtMs": nowMs,
            "expiresAtMs": nowMs + lifecycleLockLease * 1000,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: owner)
            try data.write(
                to: lockDirectory.appendingPathComponent(lifecycleLockOwnerFileName),
                options: [.atomic]
            )
            return LifecycleLock(directory: lockDirectory, token: token)
        } catch {
            try? fileManager.removeItem(at: lockDirectory)
            return nil
        }
    }

    /// Releases only the lock represented by the returned token. This avoids
    /// deleting a lock that was replaced after an unexpected interruption.
    static func releaseLifecycleLock(
        _ lock: LifecycleLock,
        fileManager: FileManager = .default
    ) {
        guard readLockOwner(
            at: lock.directory.appendingPathComponent(lifecycleLockOwnerFileName)
        )?.token == lock.token else { return }
        try? fileManager.removeItem(at: lock.directory)
    }

    /// Discover managed DerivedData directories under a home. Never follows a
    /// replaced/symlinked managed root or per-workspace DerivedData link.
    static func discoverDerivedDataDirectories(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [(name: String, url: URL)] {
        let root = managedRoot(homeDirectory: homeDirectory)
        guard isRealDirectory(root, fileManager: fileManager) else { return [] }

        var results: [(name: String, url: URL)] = []

        let legacyDerivedData = root.appendingPathComponent("DerivedData", isDirectory: true)
        if isRealDirectory(legacyDerivedData, fileManager: fileManager) {
            results.append((name: "XcodeBuildMCP: Legacy DerivedData", url: legacyDerivedData))
        }

        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        guard isRealDirectory(workspacesRoot, fileManager: fileManager),
              let workspaces = try? fileManager.contentsOfDirectory(
                  at: workspacesRoot,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return results
        }

        for workspace in workspaces where isRealDirectory(workspace, fileManager: fileManager) {
            let derivedData = workspace.appendingPathComponent("DerivedData", isDirectory: true)
            guard isRealDirectory(derivedData, fileManager: fileManager) else { continue }
            results.append((
                name: "XcodeBuildMCP: \(displayName(forWorkspaceKey: workspace.lastPathComponent))",
                url: derivedData
            ))
        }

        return results
    }

    static func displayName(forWorkspaceKey workspaceKey: String) -> String {
        guard let separator = workspaceKey.lastIndex(of: "-") else { return workspaceKey }
        let suffix = workspaceKey[workspaceKey.index(after: separator)...]
        guard suffix.count == 12, suffix.allSatisfy(\.isHexDigit) else { return workspaceKey }
        return String(workspaceKey[..<separator])
    }

    static func isRealDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let normalized = url.standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == normalized,
              let attributes = try? fileManager.attributesOfItem(atPath: normalized),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return false
        }
        return true
    }

    // MARK: - Private

    private struct LockOwner: Decodable {
        let token: String
        let pid: Int
        let purpose: String
        let acquiredAtMs: Double
        let expiresAtMs: Double
    }

    private static func readLockOwner(at url: URL) -> LockOwner? {
        guard let data = try? Data(contentsOf: url),
              let owner = try? JSONDecoder().decode(LockOwner.self, from: data),
              !owner.token.isEmpty,
              owner.pid > 0,
              !owner.purpose.isEmpty else {
            return nil
        }
        return owner
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        if pid <= 1 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

typealias XcodeBuildMCPStorage = XcodeBuildMCPDerivedDataSupport
