import AppKit
import SwiftUI
import Combine

/// Captures SwiftUI's `openWindow` action so AppKit surfaces (the menu-bar
/// popover, which lives outside the scene graph and has no working `openWindow`
/// environment) can reopen the main window after it has been closed. The main
/// window records the action on appear; the closure stays valid for the app's
/// lifetime even once the window is gone.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
    private init() {}
}

/// AppKit-backed menu-bar system monitor. A SwiftUI `MenuBarExtra` was avoided
/// here: a conditional `.window`-style `MenuBarExtra` fails to type-check, and
/// an unconditional one stalls the XCTest host's run loop. An `NSStatusItem`
/// driving an `NSPopover` (which hosts the existing SwiftUI `MenuBarMonitorView`)
/// gives the same UI with full create/destroy control and no test-host impact.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor = SystemMonitor.shared
    private var cancellable: AnyCancellable?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Persist the user's show/hide choice and ensure the item is requested
        // visible (it defaults hidden when restored from a prior autosave state).
        statusItem.autosaveName = "PureMacSystemMonitor"
        statusItem.isVisible = true

        monitor.start()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "System Monitor"
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            updateTitle()
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 248, height: 230)
        popover.contentViewController = NSHostingController(rootView: MenuBarMonitorView())
        popover.delegate = self

        // Refresh the menu-bar CPU readout each time the monitor samples.
        cancellable = monitor.$cpuUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
    }

    /// Remove the status item and release the monitor observer. Called by
    /// AppDelegate before dropping the controller so teardown runs on the main
    /// actor (a `@MainActor` deinit cannot touch isolated state safely).
    func teardown() {
        cancellable?.cancel()
        cancellable = nil
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(statusItem)
        monitor.stop()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.title = " \(Int((monitor.cpuUsage * 100).rounded()))%"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
