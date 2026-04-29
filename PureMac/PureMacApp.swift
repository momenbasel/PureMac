import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Touch TCC-protected paths so macOS registers PureMac in the
        // Full Disk Access pane on first launch (fixes issue #75).
        FullDiskAccessManager.shared.triggerRegistration()
    }
}

@main
struct PureMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var theme = ThemeManager.shared
    @AppStorage("PureMac.OnboardingComplete") private var onboardingComplete = false

    init() {
        // Enter CLI mode only when the first arg is a known command. Xcode and
        // LaunchServices inject args like -NSDocumentRevisionsDebugMode and
        // -psn_<pid> that must not be interpreted as CLI commands.
        if let first = CommandLine.arguments.dropFirst().first,
           CLI.isKnownCommand(first) {
            CLI.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    MainWindow()
                        .environmentObject(appState)
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .environmentObject(theme)
            .preferredColorScheme(theme.appearance.colorScheme)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
