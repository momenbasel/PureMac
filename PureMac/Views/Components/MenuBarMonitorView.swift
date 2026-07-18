import SwiftUI
import AppKit

/// Zero-size helper that captures SwiftUI's `openWindow` action into
/// `WindowOpener.shared` when the main window appears, so the AppKit menu-bar
/// popover can reopen the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
    }
}

/// Drop-down panel hosted in the menu-bar `NSPopover` (via `NSHostingController`)
/// with live CPU / memory / disk meters and quick actions. Kept self-contained
/// so the menu bar surface stays decoupled from the main window's `AppState`.
struct MenuBarMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text("System Monitor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 10) {
                MeterRow(title: "CPU", tint: Tint.blue,
                         fraction: monitor.cpuUsage,
                         detail: "\(Int((monitor.cpuUsage * 100).rounded()))%")
                MeterRow(title: "Memory", tint: Tint.purple,
                         fraction: monitor.memoryFraction,
                         detail: byteDetail(monitor.memoryUsed, monitor.memoryTotal))
                MeterRow(title: "Disk", tint: Tint.green,
                         fraction: monitor.diskFraction,
                         detail: byteDetail(monitor.diskUsed, monitor.diskTotal))
            }

            Divider()

            HStack {
                Button {
                    openMainWindow()
                } label: {
                    Text("Open PureMac")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit PureMac")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 252)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func byteDetail(_ used: Int64, _ total: Int64) -> String {
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return "\(u) / \(t)"
    }

    /// Bring the app forward and surface the main window. The app stays alive
    /// after its window closes only while the monitor is enabled (see
    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), so this
    /// reopens a fresh window when none is left, otherwise just focuses it.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Exclude the menu-bar popover's own panel; a real content window is
        // titled and can become main.
        if let existing = NSApp.windows.first(where: {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // No content window left — reopen via the captured openWindow action
            // (the popover has no working openWindow environment of its own).
            WindowOpener.shared.open?("main")
        }
    }
}

/// One labeled meter: title on the left, a thin tinted progress bar, and a
/// trailing numeric detail. Mirrors the restrained chrome used elsewhere.
private struct MeterRow: View {
    let title: LocalizedStringKey
    let tint: Color
    let fraction: Double
    let detail: String

    private var clamped: Double { max(0, min(1, fraction)) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.65)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * clamped))
                }
            }
            .frame(height: 6)
        }
    }
}
