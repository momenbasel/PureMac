import AppKit
import Foundation

/// Detects whether Full Disk Access (FDA) has been granted to PureMac.
/// Without FDA, macOS TCC blocks access to ~/Desktop, ~/Documents, ~/Mail,
/// ~/.Trash, and other app containers even for non-sandboxed apps.
final class FullDiskAccessManager {
    static let shared = FullDiskAccessManager()

    private init() {}

    /// Check if Full Disk Access is granted by probing TCC-protected paths.
    /// Returns true if at least one protected path is readable.
    var hasFullDiskAccess: Bool {
        // These paths are protected by TCC and require FDA to read.
        // We try multiple because some may not exist on every system.
        let protectedPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]

        for path in protectedPaths {
            if FileManager.default.isReadableFile(atPath: path) {
                return true
            }
        }

        // If none of the protected paths exist, assume FDA is not granted
        // but don't block the user - some paths may legitimately not exist
        // on a fresh system. Check if we can at least list a protected directory.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: trashPath),
           !contents.isEmpty {
            return true
        }

        // Try listing Desktop - if TCC blocks it, we get an empty array or error
        let desktopPath = "\(home)/Desktop"
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: desktopPath)
            // If Desktop exists and has files, FDA is likely granted
            // (An empty Desktop is ambiguous, so we check more paths)
            if !contents.isEmpty { return true }
        } catch {
            // Permission denied = no FDA
            return false
        }

        // Ambiguous - Desktop is empty, try one more path
        let mailDir = "\(home)/Library/Mail"
        if FileManager.default.fileExists(atPath: mailDir) {
            return FileManager.default.isReadableFile(atPath: mailDir)
        }

        // Can't determine definitively - default to warning the user
        return false
    }

    /// Opens System Settings to the Full Disk Access pane.
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
