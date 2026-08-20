import Foundation

/// Deterministic, read-only path identity normalization for macOS Data-volume
/// storage reconciliation and diagnostics.
///
/// This type performs pure string and path-component manipulation only. It
/// never accesses the filesystem, never follows arbitrary symlinks, never calls
/// shell commands or diskutil, and has zero side effects.
public enum StoragePathNormalizer: Sendable {
    private static let dataVolumePrefix = "/System/Volumes/Data"

    /// Normalizes a macOS path to its canonical storage identity path.
    ///
    /// Rules applied:
    /// 1. Standardizes redundant slashes, "." and ".." segments via standard URL path normalization.
    /// 2. Synthetic root aliases:
    ///    - `/var` or `/var/...` -> `/private/var` or `/private/var/...`
    ///    - `/etc` or `/etc/...` -> `/private/etc` or `/private/etc/...`
    ///    - `/tmp` or `/tmp/...` -> `/private/tmp` or `/private/tmp/...`
    /// 3. Data-volume firmlink aliases:
    ///    - `/System/Volumes/Data/private` or `/System/Volumes/Data/private/...` -> `/private` or `/private/...`
    ///    - `/System/Volumes/Data/Users` or `/System/Volumes/Data/Users/...` -> `/Users` or `/Users/...`
    ///    - `/System/Volumes/Data/Library` or `/System/Volumes/Data/Library/...` -> `/Library` or `/Library/...`
    ///    - `/System/Volumes/Data/Applications` or `/System/Volumes/Data/Applications/...` -> `/Applications` or `/Applications/...`
    ///    - `/System/Volumes/Data/opt` or `/System/Volumes/Data/opt/...` -> `/opt` or `/opt/...`
    ///    - `/System/Volumes/Data/usr/local` or `/System/Volumes/Data/usr/local/...` -> `/usr/local` or `/usr/local/...`
    ///    - `/System/Volumes/Data/var` or `/System/Volumes/Data/var/...` -> `/private/var` or `/private/var/...`
    ///    - `/System/Volumes/Data/etc` or `/System/Volumes/Data/etc/...` -> `/private/etc` or `/private/etc/...`
    ///    - `/System/Volumes/Data/tmp` or `/System/Volumes/Data/tmp/...` -> `/private/tmp` or `/private/tmp/...`
    ///
    /// Exact prefix boundaries are strictly enforced so similar names such as
    /// `/private2`, `/various`, `/System/Volumes/Database`, etc. are NOT treated as aliases.
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path

        // Check /var, /etc, /tmp
        if standardized == "/var" {
            return "/private/var"
        } else if standardized.hasPrefix("/var/") {
            return "/private/var" + standardized.dropFirst("/var".count)
        }

        if standardized == "/etc" {
            return "/private/etc"
        } else if standardized.hasPrefix("/etc/") {
            return "/private/etc" + standardized.dropFirst("/etc".count)
        }

        if standardized == "/tmp" {
            return "/private/tmp"
        } else if standardized.hasPrefix("/tmp/") {
            return "/private/tmp" + standardized.dropFirst("/tmp".count)
        }

        // Check /System/Volumes/Data firmlinks
        if standardized == dataVolumePrefix {
            return dataVolumePrefix
        }

        if standardized.hasPrefix(dataVolumePrefix + "/") {
            let relative = String(standardized.dropFirst((dataVolumePrefix + "/").count))

            // Check specific known firmlinks under /System/Volumes/Data
            if relative == "private" {
                return "/private"
            } else if relative.hasPrefix("private/") {
                return "/" + relative
            }

            if relative == "Users" {
                return "/Users"
            } else if relative.hasPrefix("Users/") {
                return "/" + relative
            }

            if relative == "Library" {
                return "/Library"
            } else if relative.hasPrefix("Library/") {
                return "/" + relative
            }

            if relative == "Applications" {
                return "/Applications"
            } else if relative.hasPrefix("Applications/") {
                return "/" + relative
            }

            if relative == "opt" {
                return "/opt"
            } else if relative.hasPrefix("opt/") {
                return "/" + relative
            }

            if relative == "usr/local" {
                return "/usr/local"
            } else if relative.hasPrefix("usr/local/") {
                return "/" + relative
            }

            if relative == "var" {
                return "/private/var"
            } else if relative.hasPrefix("var/") {
                return "/private/var" + relative.dropFirst("var".count)
            }

            if relative == "etc" {
                return "/private/etc"
            } else if relative.hasPrefix("etc/") {
                return "/private/etc" + relative.dropFirst("etc".count)
            }

            if relative == "tmp" {
                return "/private/tmp"
            } else if relative.hasPrefix("tmp/") {
                return "/private/tmp" + relative.dropFirst("tmp".count)
            }
        }

        return standardized
    }

    /// Checks if a parent path contains or is equal to a child path using normalized identities.
    public static func contains(parent: String, child: String) -> Bool {
        let normParent = normalize(parent)
        let normChild = normalize(child)
        if normParent == normChild { return true }
        if normParent == "/" { return normChild.hasPrefix("/") }
        return normChild.hasPrefix(normParent + "/")
    }

    /// Checks if two paths overlap (either one contains the other) using normalized identities.
    public static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        contains(parent: left, child: right) || contains(parent: right, child: left)
    }

    /// Returns the parent path of a path using normalized identities.
    public static func parentPath(of path: String) -> String {
        let norm = normalize(path)
        guard norm != "/" else { return "/" }
        return URL(fileURLWithPath: norm).deletingLastPathComponent().path
    }

    /// Returns whether a path is a known system-managed / system-protected location on macOS.
    public static func isSystemProtectedLocation(_ path: String) -> Bool {
        let norm = normalize(path)

        // Data volume root system structures
        if norm == "/System/Volumes/Data/.DocumentRevisions-V100" || norm.hasPrefix("/System/Volumes/Data/.DocumentRevisions-V100/")
            || norm == "/System/Volumes/Data/.Spotlight-V100" || norm.hasPrefix("/System/Volumes/Data/.Spotlight-V100/")
            || norm == "/System/Volumes/Data/.fseventsd" || norm.hasPrefix("/System/Volumes/Data/.fseventsd/")
            || norm == "/System/Volumes/Data/.Trashes" || norm.hasPrefix("/System/Volumes/Data/.Trashes/") {
            return true
        }

        // Also check if someone passed non-normalized root data volume paths
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized == "/.DocumentRevisions-V100" || standardized.hasPrefix("/.DocumentRevisions-V100/")
            || standardized == "/.Spotlight-V100" || standardized.hasPrefix("/.Spotlight-V100/")
            || standardized == "/.fseventsd" || standardized.hasPrefix("/.fseventsd/")
            || standardized == "/.Trashes" || standardized.hasPrefix("/.Trashes/") {
            return true
        }

        // /private/var and /private/etc protected subtrees
        if norm == "/private/var/audit" || norm.hasPrefix("/private/var/audit/")
            || norm == "/private/var/root" || norm.hasPrefix("/private/var/root/")
            || norm == "/private/var/protected" || norm.hasPrefix("/private/var/protected/")
            || norm == "/private/var/db" || norm.hasPrefix("/private/var/db/")
            || norm == "/private/var/agentx" || norm.hasPrefix("/private/var/agentx/")
            || norm == "/private/etc/cups/certs" || norm.hasPrefix("/private/etc/cups/certs/") {
            return true
        }

        return false
    }
}
