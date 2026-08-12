import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the optional menu-bar status item. Nil until the monitor is enabled.
    private var menuBarController: MenuBarController?

    /// Normally PureMac quits when its window closes. When the menu-bar system
    /// monitor is enabled the app stays resident so the meters keep updating in
    /// the menu bar; "Open PureMac" in that menu reopens the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "settings.general.menuBarMonitor")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Install the menu-bar monitor if the user has it enabled. Never under
        // XCTest — the status-item machinery would stall the test-host run loop.
        if NSClassFromString("XCTestCase") == nil {
            syncMenuBarMonitor()
            NotificationCenter.default.addObserver(
                self, selector: #selector(syncMenuBarMonitor),
                name: .pureMacMenuBarMonitorChanged, object: nil
            )
        }
        // Touch TCC-protected paths so macOS registers PureMac in the
        // Full Disk Access pane on first launch (fixes issue #75).
        FullDiskAccessManager.shared.triggerRegistration()
        // Register the Finder Services provider so "Uninstall with PureMac"
        // appears when an .app bundle is right-clicked (issue #109).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Finder Services entry point. Declared in Info.plist as NSMessage
    /// `uninstallApp`; receives the right-clicked .app via the pasteboard and
    /// hands it to AppState through a notification. Brings PureMac forward so
    /// the user lands on the uninstall scan.
    @objc func uninstallApp(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let appURL = urls.first(where: { $0.pathExtension == "app" }) else {
            error?.pointee = String(localized: "Select an application (.app) to uninstall.") as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        // Buffer the path for the cold-launch case (AppState may not exist yet,
        // and NotificationCenter does not replay); AppState drains it in init.
        ExternalUninstallBuffer.pendingPath = appURL.path
        NotificationCenter.default.post(
            name: .pureMacExternalUninstall,
            object: nil,
            userInfo: ["path": appURL.path]
        )
    }

    /// Create or tear down the menu-bar status item to match the current
    /// Settings toggle. Posted to whenever the toggle flips so it takes effect
    /// without a relaunch.
    @objc func syncMenuBarMonitor() {
        let enabled = UserDefaults.standard.bool(forKey: "settings.general.menuBarMonitor")
        if enabled, menuBarController == nil {
            menuBarController = MenuBarController()
        } else if !enabled, let controller = menuBarController {
            controller.teardown()
            menuBarController = nil
        }
    }
}

extension Notification.Name {
    /// Posted when the "Show system monitor in menu bar" Settings toggle flips,
    /// so AppDelegate can add/remove the status item live.
    static let pureMacMenuBarMonitorChanged = Notification.Name("PureMac.MenuBarMonitorChanged")
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
        WindowGroup(id: "main") {
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
            // Record the openWindow action so the menu-bar popover can reopen
            // this window after it's been closed (the popover lives outside the
            // scene graph and can't use openWindow itself).
            .background(WindowOpenerCapture())
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Updates") {
                Button("Check for Updates") {
                    UpdateService.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // The opt-in menu-bar system monitor is an AppKit NSStatusItem managed
        // by AppDelegate/MenuBarController rather than a SwiftUI MenuBarExtra:
        // a conditional `.window`-style MenuBarExtra fails to type-check, and an
        // unconditional one sets up status-item machinery that hangs the XCTest
        // host. The AppKit controller is only created when enabled and never
        // under tests, sidestepping both problems.
    }
}
