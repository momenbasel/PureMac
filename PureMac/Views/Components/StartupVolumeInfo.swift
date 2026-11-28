import AppKit

struct StartupVolumeInfo {
    let name: String
    let icon: NSImage

    static let current: StartupVolumeInfo = {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let info = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        let name = [info?.volumeLocalizedName, info?.volumeName].compactMap { $0 }
            .first { !$0.isEmpty && $0 != "/" } ?? String(localized: "Startup disk")
        return StartupVolumeInfo(name: name, icon: NSWorkspace.shared.icon(forFile: root.path))
    }()
}
