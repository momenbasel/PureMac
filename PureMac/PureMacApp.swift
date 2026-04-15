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

    init() {
        let cliArguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        if !cliArguments.isEmpty {
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

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
