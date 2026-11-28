import AppKit
import SwiftUI

/// Draggable PureMac.app affordance. The user grabs the icon out of our sheet
/// and drops it into the Full Disk Access list inside System Settings, which
/// auto-adds the bundle without making them hunt for it in Finder.
///
/// macOS's Privacy & Security panes accept file-URL drops in their service
/// lists. We expose the running app's bundle URL via `NSItemProvider` so the
/// drop registers as a legitimate filesystem drag — identical to dragging
/// from Finder, just sourced from inside the app.
struct AppBundleDragHandle: View {
    @State private var hovering = false

    private var bundleURL: URL {
        Bundle.main.bundleURL
    }

    var body: some View {
        VStack(spacing: 8) {
            appIcon
                .frame(width: 44, height: 44)
                .padding(5)
                .background {
                    if hovering {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    }
                }

            VStack(spacing: 1) {
                Text("PureMac.app")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Drag to the Settings list")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onHover { hovering = $0 }
        .help("Drag this icon into the Full Disk Access list in System Settings.")
        // NSItemProvider(object: NSURL) is exactly what Finder emits when
        // you drag an .app — it exposes both the file representation and
        // the URL string under public.file-url, which is the shape System
        // Settings' Privacy panes are built to receive. `contentsOf:` works
        // too but registers as a generic file copy operation; Settings'
        // FDA list reads the URL representation directly.
        .onDrag {
            let provider = NSItemProvider(object: bundleURL as NSURL)
            provider.suggestedName = bundleURL.lastPathComponent
            return provider
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsImage = NSWorkspace.shared.icon(forFile: bundleURL.path) as NSImage? {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 36))
                .foregroundStyle(Tint.blue)
        }
    }
}
