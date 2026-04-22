import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

@main
struct PureMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("PureMac.OnboardingComplete") private var onboardingComplete = false
    @Environment(\.scenePhase) private var scenePhase

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
            if onboardingComplete {
                MainWindow()
                    .environmentObject(appState)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                OnboardingView(isComplete: $onboardingComplete)
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        // When the app becomes active (e.g., after returning from System Settings)
        // re-check Full Disk Access immediately so permissions are detected
        // without waiting for the 60 s periodic timer.
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                appState.checkFullDiskAccess()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
