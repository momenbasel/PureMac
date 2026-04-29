import AppKit
import Foundation

/// Detects whether Full Disk Access (FDA) has been granted to PureMac.
/// Without FDA, macOS TCC blocks access to ~/Library/Mail, ~/Library/Safari,
/// /Library/Application Support/com.apple.TCC, and other protected locations.
final class FullDiskAccessManager {
    static let shared = FullDiskAccessManager()

    private init() {}

    /// Check if Full Disk Access is granted by attempting a real read of a
    /// TCC-protected file. We use FileHandle/Data — not isReadableFile or
    /// fileExists — because the metadata APIs short-circuit before TCC fires
    /// and so don't register the calling app in the FDA list.
    var hasFullDiskAccess: Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/CloudTabs.db").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail").path,
        ]

        for path in probes {
            if canActuallyRead(path: path) { return true }
        }
        return false
    }

    /// Real-read probe. Performs the syscall TCC actually evaluates, so
    /// the OS records PureMac as the requester and adds it to the FDA pane.
    /// Directories use contentsOfDirectory; files use FileHandle.
    @discardableResult
    private func canActuallyRead(path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        if isDir.boolValue {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return true
            } catch {
                return false
            }
        } else {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                return false
            }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 1)) != nil
        }
    }

    /// Force PureMac to appear in the Full Disk Access list.
    ///
    /// The OS only registers an app in the FDA pane after that app itself
    /// makes a TCC-gated syscall. Metadata lookups (fileExists, isReadableFile)
    /// don't qualify, and delegating to Finder via AppleScript registers
    /// *Finder* — not PureMac. So at launch we touch a few protected paths
    /// directly. The reads will fail until the user grants access; that's
    /// fine — the failed attempts are what register us.
    func triggerRegistration() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.canActuallyRead(path: "/Library/Application Support/com.apple.TCC/TCC.db")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            _ = self.canActuallyRead(path: "\(home)/Library/Mail")
            _ = self.canActuallyRead(path: "\(home)/Library/Safari/CloudTabs.db")
        }
    }

    /// Opens System Settings to the Full Disk Access pane.
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Reveal the running PureMac.app bundle in Finder so the user can drag
    /// it into the Full Disk Access list when the OS hasn't auto-registered
    /// it (common with Homebrew installs that strip the quarantine attribute).
    func revealAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    /// Reset PureMac's TCC entries so the OS can re-register the bundle.
    /// Useful when the bundle was replaced (Homebrew upgrade, manual move)
    /// and the existing TCC row points at a stale code-signing identity.
    /// Returns true if the reset command exited cleanly.
    @discardableResult
    func resetFullDiskAccess() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.puremac.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "SystemPolicyAllFiles", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
