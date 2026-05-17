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
        // Do not start automatic checking by default; keep control minimal.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

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
