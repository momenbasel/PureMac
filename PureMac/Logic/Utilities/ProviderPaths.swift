import Foundation

/// Hard denylist for cloud File Provider state (issue #142).
///
/// iCloud Drive, and every other provider that plugs into FileProvider.framework,
/// keeps a database of what it believes is on disk. Removing a file underneath it
/// with `unlink` does not tell the provider anything, so its snapshot and the
/// filesystem drift apart. `fileproviderctl check` then reports invariants like
/// `is_on_disk_but_not_in_FS_Snapshot`, and Finder copies out of iCloud Drive slow
/// from instant to tens of seconds because every read goes through reconciliation.
/// A user reported exactly this after one cleanup: 513 of 19693 files broken, and
/// the live service rebuilt the inconsistent state ~10s after each repair.
///
/// These directories are implementation detail owned by `bird`, `cloudd`, and
/// `fileproviderd`. They are never junk, they are never safe to reclaim, and no
/// amount of space saved justifies corrupting a user's cloud sync state.
enum ProviderPaths {

    /// Roots that must never be scanned, offered, or deleted. Any path equal to
    /// or beneath one of these is off limits.
    static var deniedRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // iCloud Drive user-visible root and its per-app containers.
            "\(home)/Library/Mobile Documents",
            // Third-party providers (Dropbox, OneDrive, Google Drive, ...).
            "\(home)/Library/CloudStorage",
            // FileProvider framework state and per-provider domains.
            "\(home)/Library/Application Support/FileProvider",
            "\(home)/Library/Application Support/CloudDocs",
            // Provider extension containers.
            "\(home)/Library/Daemon Containers",
            // Live databases, not reclaimable caches, despite living in Caches.
            "\(home)/Library/Caches/CloudKit",
            "\(home)/Library/Caches/com.apple.bird",
            "\(home)/Library/Caches/com.apple.cloudkit",
            "\(home)/Library/Caches/com.apple.cloudd",
            "\(home)/Library/Caches/com.apple.FileProvider",
        ]
    }

    /// True when `path` is inside provider-owned state and must be left alone.
    ///
    /// The check runs against both the literal path and its symlink-resolved
    /// form. That second pass matters: with "Desktop & Documents Folders" sync
    /// enabled, `~/Desktop` and `~/Documents` resolve into
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, so an innocuous-looking
    /// root can walk straight into iCloud state.
    static func isProviderOwned(_ path: String) -> Bool {
        let candidates = [
            (path as NSString).standardizingPath,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
        ]
        for candidate in candidates {
            // Any component of the form `com~apple~CloudDocs` (or any other
            // provider domain) marks provider territory regardless of location.
            if candidate.contains("com~apple~") { return true }
            for root in deniedRoots where candidate == root || candidate.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }
}
