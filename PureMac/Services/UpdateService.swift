import Foundation
import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private init() {
        #if canImport(Sparkle)
        // Create the standard updater controller but do not start it automatically.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

        // Install lightweight runtime observers to surface Sparkle notifications to the app console.
        installDebugObservers()

        // If the updater's stored preference indicates automatic checks, start the updater so Sparkle can schedule checks.
        if let updater = updaterController?.updater, updater.automaticallyChecksForUpdates {
            updaterController?.startUpdater()
        }
        #endif
    }

        #if canImport(Sparkle)
        private var debugObservers: [Any] = []

        private func installDebugObservers() {
            let nc = NotificationCenter.default

            debugObservers.append(nc.addObserver(forName: NSNotification.Name("SUUpdaterDidFinishLoadingAppCastNotification"), object: nil, queue: .main) { note in
                print("NOTIFICATION_APPCAST")
                if let appcast = note.userInfo?["appcast"] as? SUAppcast {
                    print("APPCAST_LOADED \(appcast.items.count)")
                }
            })

            debugObservers.append(nc.addObserver(forName: NSNotification.Name("SUUpdaterDidFindValidUpdateNotification"), object: nil, queue: .main) { _ in
                print("NOTIFICATION_FOUND")
            })

            debugObservers.append(nc.addObserver(forName: NSNotification.Name("SUUpdaterDidNotFindUpdateNotification"), object: nil, queue: .main) { _ in
                print("NOTIFICATION_NOT_FOUND")
            })

            debugObservers.append(nc.addObserver(forName: NSNotification.Name("SUUpdaterDidAbortWithErrorNotification"), object: nil, queue: .main) { note in
                let msg = "NOTIFICATION_ABORTED \(String(describing: note.userInfo?["error"]))"
                print(msg)
                self.appendDebugLog(msg)
            })
            // Global observer: capture any Sparkle-related notifications for debugging.
            debugObservers.append(nc.addObserver(forName: nil, object: nil, queue: .main) { note in
                let name = note.name.rawValue
                if name.contains("SU") || name.lowercased().contains("sparkle") {
                    let msg = "NOTIF: \(name) userInfo=\(String(describing: note.userInfo))"
                    print(msg)
                    self.appendDebugLog(msg)
                }
            })
        }

        private func appendDebugLog(_ message: String) {
            let fm = FileManager.default
            let logDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PureMac")
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("update-debug.log")
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if fm.fileExists(atPath: logFile.path) {
                    if let fh = try? FileHandle(forWritingTo: logFile) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        try? fh.close()
                    }
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
        #endif

    #if canImport(Sparkle)
    var updater: SPUUpdater? { updaterController?.updater }

    /// Set whether Sparkle should automatically check for updates.
    func setAutomaticallyChecks(_ enabled: Bool) {
        DispatchQueue.main.async {
            guard let updater = self.updaterController?.updater else {
                UserDefaults.standard.set(enabled, forKey: "settings.updates.checkAutomatically")
                return
            }
            updater.automaticallyChecksForUpdates = enabled
            if enabled {
                self.updaterController?.startUpdater()
            }
            updater.resetUpdateCycleAfterShortDelay()
        }
    }

    /// Set the Sparkle update check interval (seconds).
    func setUpdateInterval(_ seconds: TimeInterval) {
        DispatchQueue.main.async {
            if let updater = self.updaterController?.updater {
                updater.updateCheckInterval = seconds
                updater.resetUpdateCycleAfterShortDelay()
            } else {
                // Fallback: persist to UserDefaults for older code paths.
                let raw: String
                switch Int(seconds) {
                case 60 * 60 * 24: raw = "Daily"
                case 60 * 60 * 24 * 30: raw = "Monthly"
                default: raw = "Weekly"
                }
                UserDefaults.standard.set(raw, forKey: "settings.updates.checkInterval")
            }
        }
    }
    #endif

    func checkForUpdates() {
        #if canImport(Sparkle)
        DispatchQueue.main.async {
            // Only start the Sparkle updater if an appcast/feed URL is configured.
            if let _ = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String {
                self.updaterController?.startUpdater()
                self.updaterController?.updater.checkForUpdates()
            } else {
                // Fallback: open Releases page when no feed is configured.
                if let url = URL(string: "https://github.com/momenbasel/PureMac/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        #else
        // Fallback: open Releases page
        if let url = URL(string: "https://github.com/momenbasel/PureMac/releases/latest") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
