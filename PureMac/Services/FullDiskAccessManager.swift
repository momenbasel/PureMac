import AppKit
import Foundation

/// Detects whether Full Disk Access (FDA) has been granted to PureMac.
/// Without FDA, macOS TCC blocks access to ~/Desktop, ~/Documents, ~/Mail,
/// ~/.Trash, and other app containers even for non-sandboxed apps.
final class FullDiskAccessManager {
    static let shared = FullDiskAccessManager()
    private init() {}

    /// Check if Full Disk Access is granted by attempting a real read of a
    /// TCC-protected location. The heuristic is:
    /// - Try to read a file from a TCC-protected directory (~/Library/Mail)
    /// - If we get EPERM/EACCES, FDA is denied
    /// - If we can read the file (or the file doesn't exist), FDA is likely granted
    /// - Fallback: check that Desktop exists and is readable
    var hasFullDiskAccess: Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        // Primary probe: ~/Library/Mail directory contents.
        // Even if the user has never used Mail, the directory may not exist.
        // In that case, fall back to checking Desktop readability.
        let mailPath = "\(home)/Library/Mail"

        if fileManager.fileExists(atPath: mailPath) {
            // TCC blocks _reading file contents_ but not directory traversal.
            // The best signal: can we read a known mailbox file if it exists?
            // Mail stores messages as individual files in subdirectories.
            // Try enumerating the directory; if enumeration fails with EPERM, FDA denied.
            // If enumeration succeeds, FDA grants at least some access to that location.
            do {
                _ = try fileManager.contentsOfDirectory(atPath: mailPath)
                // If we got here, we successfully enumerated Mail dir → FDA likely granted
                return true
            } catch {
                // EPERM or EACCES = permission denied by TCC = no FDA
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain &&
                   (nsError.code == NSFileReadNoPermissionError ||
                    nsError.code == NSFileWriteNoPermissionError) {
                    return false
                }
                // Some other error (file not found, etc.) — try fallback checks
            }
        }

        // Fallback 1: Check Desktop has readable files (not just empty dir).
        // An empty Desktop is ambiguous; a non-empty readable Desktop suggests FDA.
        let desktopPath = "\(home)/Desktop"
        if let desktopContents = try? fileManager.contentsOfDirectory(atPath: desktopPath),
           !desktopContents.isEmpty {
            // Verify at least one file is actually readable (TCC might hide contents)
            let hasReadable = desktopContents.contains { item in
                let fullPath = (desktopPath as NSString).appendingPathComponent(item)
                return fileManager.isReadableFile(atPath: fullPath)
            }
            if hasReadable { return true }
        }

        // Fallback 2: Safari Bookmarks (historically TCC-protected for some macOS versions)
        let safariPath = "\(home)/Library/Safari/Bookmarks.plist"
        if fileManager.isReadableFile(atPath: safariPath) {
            return true
        }

        // Fallback 3: Documents directory has readable files
        let docsPath = "\(home)/Documents"
        if let docsContents = try? fileManager.contentsOfDirectory(atPath: docsPath),
           !docsContents.isEmpty {
            let hasReadable = docsContents.contains { item in
                let fullPath = (docsPath as NSString).appendingPathComponent(item)
                return fileManager.isReadableFile(atPath: fullPath)
            }
            if hasReadable { return true }
        }

        // Cannot confirm FDA — assume not granted to be safe
        return false
    }

    /// Opens System Settings to the Full Disk Access pane.
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
