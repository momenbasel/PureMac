import Foundation
import AppKit

struct InstalledApp: Identifiable, Hashable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let path: URL
    let icon: NSImage
    let size: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}

final class AppInfoFetcher {
    static let shared = AppInfoFetcher()
    private let fileManager = FileManager.default

    private init() {}

    func fetchInstalledApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seenBundleIDs: Set<String> = []

        let searchPaths = [
            "/Applications",
            "\(home)/Applications",
            "/System/Applications",
        ]

        for searchPath in searchPaths {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: searchPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }

                // Skip subdirectories inside .app bundles
                enumerator.skipDescendants()

                guard let app = loadAppInfo(from: url),
                      !seenBundleIDs.contains(app.bundleIdentifier) else { continue }

                seenBundleIDs.insert(app.bundleIdentifier)
                apps.append(app)
            }
        }

        return apps.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func loadAppInfo(from url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)

        let size = appSize(at: url)

        return InstalledApp(
            id: UUID(),
            appName: appName,
            bundleIdentifier: bundleID,
            path: url,
            icon: icon,
            size: size
        )
    }

    private func appSize(at url: URL) -> Int64 {
        // Use Spotlight metadata for fast size lookup
        if let item = NSMetadataItem(url: url),
           let size = item.value(forAttribute: kMDItemFSSize as String) as? Int64 {
            return size
        }

        // Fallback: enumerate files
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 5000 { break }
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
