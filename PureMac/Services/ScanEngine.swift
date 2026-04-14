import Foundation
import AppKit

actor ScanEngine {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private struct CleanupTarget {
        let name: String
        let path: String
    }

    // MARK: - Public API

    func scanCategory(_ category: CleaningCategory) async -> CategoryResult {
        switch category {
        case .smartScan:
            return CategoryResult(category: category, items: [], totalSize: 0)
        case .systemJunk:
            return scanSystemJunk()
        case .userCache:
            return scanUserCache()
        case .aiApps:
            return scanAIApps()
        case .mailAttachments:
            return scanMailAttachments()
        case .trashBins:
            return scanTrash()
        case .largeFiles:
            return scanLargeFiles()
        case .purgeableSpace:
            return scanPurgeableSpace()
        case .xcodeJunk:
            return scanXcodeJunk()
        case .brewCache:
            return scanBrewCache()
        case .appUninstaller:
            return CategoryResult(category: category, items: [], totalSize: 0)
        }
    }

    func getDiskInfo() -> DiskInfo {
        var info = DiskInfo()
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            if let total = attrs[.systemSize] as? Int64 {
                info.totalSpace = total
            }
            if let free = attrs[.systemFreeSize] as? Int64 {
                info.freeSpace = free
            }
            info.usedSpace = info.totalSpace - info.freeSpace

            // Calculate purgeable space from Time Machine local snapshots
            // Purgeable = space used by local snapshots that macOS can reclaim
            info.purgeableSpace = getLocalSnapshotSize()
        } catch {
            // Silently fail - disk info is supplementary
        }
        return info
    }

    // MARK: - Scanners

    private func scanSystemJunk() -> CategoryResult {
        var items: [CleanableItem] = []
        var totalSize: Int64 = 0

        let systemPaths = [
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "\(home)/Library/Logs",
            "/tmp",
            "/private/var/tmp",
        ]

        for path in systemPaths {
            let scanned = scanDirectory(path: path, category: .systemJunk, recursive: true, maxDepth: 3)
            items.append(contentsOf: scanned)
        }

        totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .systemJunk, items: items, totalSize: totalSize)
    }

    private func scanUserCache() -> CategoryResult {
        var items: [CleanableItem] = []
        // Exclude vendor roots claimed by dedicated categories from the broad
        // ~/Library/Caches pass, then re-add the vendor root explicitly below so
        // unrelated app caches remain visible and we only avoid double-counting.
        let excludedRootPaths = Set([
            "\(home)/Library/Caches/com.apple.Safari",
            "\(home)/Library/Caches/Google",
            "\(home)/Library/Caches/Firefox",
            "\(home)/Library/Caches/com.spotify.client",
            "\(home)/Library/Caches/com.microsoft.VSCode",
            "\(home)/Library/Caches/Slack",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Library/Caches/com.apple.dt.Xcode",
            "\(home)/Library/Caches/pip",
            "\(home)/Library/Caches/com.electron.ollama",
            "\(home)/Library/Caches/ollama",
        ].map(normalizePath))

        let cachePaths = [
            "\(home)/Library/Caches",
            "\(home)/Library/Caches/com.apple.Safari",
            "\(home)/Library/Caches/Google",
            "\(home)/Library/Caches/Firefox",
            "\(home)/Library/Caches/com.spotify.client",
            "\(home)/Library/Caches/com.microsoft.VSCode",
            "\(home)/Library/Caches/Slack",
        ]

        for path in cachePaths {
            let scanned = scanDirectory(
                path: path,
                category: .userCache,
                recursive: false,
                maxDepth: 1,
                excluding: path == "\(home)/Library/Caches" ? excludedRootPaths : Set<String>()
            )
            items.append(contentsOf: scanned)
        }

        // Also scan for npm/pip/yarn caches
        let devCaches = [
            "\(home)/.npm/_cacache",
            "\(home)/.cache/pip",
            "\(home)/.cache/yarn",
            "\(home)/.cache/pnpm",
            "\(home)/Library/Caches/pip",
        ]

        for path in devCaches {
            if let item = makeCleanupItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .userCache
            ) {
                items.append(item)
            }
        }

        let uniqueItems = deduplicatedItems(items)
        let totalSize = uniqueItems.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .userCache, items: uniqueItems, totalSize: totalSize)
    }

    private func scanAIApps() -> CategoryResult {
        let targets = [
            CleanupTarget(
                name: "Ollama Logs",
                path: "\(home)/.ollama/logs"
            ),
            CleanupTarget(
                name: "Ollama Cache",
                path: "\(home)/Library/Caches/ollama"
            ),
            CleanupTarget(
                name: "Ollama Electron Cache",
                path: "\(home)/Library/Caches/com.electron.ollama"
            ),
            CleanupTarget(
                name: "Ollama WebKit Data",
                path: "\(home)/Library/WebKit/com.electron.ollama"
            ),
            CleanupTarget(
                name: "Ollama Saved State",
                path: "\(home)/Library/Saved Application State/com.electron.ollama.savedState"
            ),
            CleanupTarget(
                name: "LM Studio Server Logs",
                path: "\(home)/.lmstudio/server-logs"
            ),
        ]

        let items = deduplicatedItems(targets.compactMap { target in
            makeCleanupItem(name: target.name, path: target.path, category: .aiApps)
        })
        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .aiApps, items: items.sorted { $0.size > $1.size }, totalSize: totalSize)
    }

    private func scanMailAttachments() -> CategoryResult {
        var items: [CleanableItem] = []

        let mailPaths = [
            "\(home)/Library/Mail Downloads",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ]

        for path in mailPaths {
            let scanned = scanDirectory(path: path, category: .mailAttachments, recursive: true, maxDepth: 3)
            items.append(contentsOf: scanned)
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .mailAttachments, items: items, totalSize: totalSize)
    }

    private func scanTrash() -> CategoryResult {
        var items: [CleanableItem] = []

        let trashPath = "\(home)/.Trash"
        let scanned = scanDirectory(path: trashPath, category: .trashBins, recursive: false, maxDepth: 1)
        items.append(contentsOf: scanned)

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .trashBins, items: items, totalSize: totalSize)
    }

    private func scanLargeFiles() -> CategoryResult {
        var items: [CleanableItem] = []
        let minSize: Int64 = 100 * 1024 * 1024 // 100 MB
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!

        let searchPaths = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
        ]

        for basePath in searchPaths {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var depth = 0
            for case let fileURL as URL in enumerator {
                depth += 1
                if depth > 5000 { break } // Safety limit

                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      let isFile = resourceValues.isRegularFile, isFile,
                      let fileSize = resourceValues.fileSize
                else { continue }

                let size = Int64(fileSize)
                let modDate = resourceValues.contentModificationDate

                if size > minSize || (modDate != nil && modDate! < oneYearAgo && size > 10 * 1024 * 1024) {
                    items.append(CleanableItem(
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        size: size,
                        category: .largeFiles,
                        isSelected: false, // Don't auto-select large files
                        lastModified: modDate
                    ))
                }
            }
        }

        items.sort { $0.size > $1.size }
        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .largeFiles, items: items, totalSize: totalSize)
    }

    private func scanPurgeableSpace() -> CategoryResult {
        var items: [CleanableItem] = []
        var totalSize: Int64 = 0

        // List Time Machine local snapshots - these are the main purgeable items
        let snapshots = getLocalSnapshots()
        for snapshot in snapshots {
            items.append(CleanableItem(
                name: "TM Snapshot: \(snapshot.name)",
                path: snapshot.name,
                size: snapshot.size,
                category: .purgeableSpace,
                isSelected: true,
                lastModified: snapshot.date
            ))
            totalSize += snapshot.size
        }

        // If no snapshots found but system reports purgeable, show a single entry
        if items.isEmpty {
            let diskInfo = getDiskInfo()
            if diskInfo.purgeableSpace > 0 {
                items.append(CleanableItem(
                    name: "APFS Purgeable Space",
                    path: "/",
                    size: diskInfo.purgeableSpace,
                    category: .purgeableSpace,
                    isSelected: true,
                    lastModified: nil
                ))
                totalSize = diskInfo.purgeableSpace
            }
        }

        return CategoryResult(category: .purgeableSpace, items: items, totalSize: totalSize)
    }

    private func scanXcodeJunk() -> CategoryResult {
        var items: [CleanableItem] = []

        let xcodePaths = [
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Caches/com.apple.dt.Xcode",
        ]

        for path in xcodePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .xcodeJunk,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .xcodeJunk, items: items, totalSize: totalSize)
    }

    private func scanBrewCache() -> CategoryResult {
        var items: [CleanableItem] = []

        // Homebrew cache locations (Apple Silicon + Intel)
        let brewCachePaths = [
            "\(home)/Library/Caches/Homebrew",
            "/opt/homebrew/Caskroom/.metadata",
            "/usr/local/Caskroom/.metadata",
            "/opt/homebrew/Cellar/.metadata",
            "/usr/local/Cellar/.metadata",
        ]

        for path in brewCachePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .brewCache,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .brewCache, items: items, totalSize: totalSize)
    }

    // MARK: - Helpers

    private func scanDirectory(
        path: String,
        category: CleaningCategory,
        recursive: Bool,
        maxDepth: Int,
        excluding excludedPaths: Set<String> = []
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []

        guard fileManager.fileExists(atPath: path),
              fileManager.isReadableFile(atPath: path) else { return [] }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for item in contents {
                let fullPath = (path as NSString).appendingPathComponent(item)
                if excludedPaths.contains(normalizePath(fullPath)) {
                    continue
                }

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

                if isDir.boolValue {
                    let size = directorySize(path: fullPath)
                    if size > 1024 { // Skip tiny entries
                        items.append(CleanableItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: true,
                            lastModified: fileModDate(path: fullPath)
                        ))
                    }
                } else {
                    if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                       let size = attrs[.size] as? Int64, size > 1024 {
                        items.append(CleanableItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: true,
                            lastModified: attrs[.modificationDate] as? Date
                        ))
                    }
                }
            }
        } catch {
            // Permission denied or other error - skip silently
        }

        return items
    }

    private func makeCleanupItem(name: String, path: String, category: CleaningCategory) -> CleanableItem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: path) else { return nil }

        if isDirectory.boolValue {
            let size = directorySize(path: path)
            guard size > 1024 else { return nil }
            return CleanableItem(
                name: name,
                path: path,
                size: size,
                category: category,
                isSelected: true,
                lastModified: fileModDate(path: path)
            )
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size > 1024 else { return nil }

        return CleanableItem(
            name: name,
            path: path,
            size: size,
            category: category,
            isSelected: true,
            lastModified: attrs[.modificationDate] as? Date
        )
    }

    private func deduplicatedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        var seenPaths: Set<String> = []
        var uniqueItems: [CleanableItem] = []

        for item in items {
            let normalizedPath = normalizePath(item.path)
            if seenPaths.insert(normalizedPath).inserted {
                uniqueItems.append(item)
            }
        }

        return uniqueItems
    }

    private func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func directorySize(path: String) -> Int64 {
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 10000 { break } // Safety limit for very large directories

            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  let isFile = values.isRegularFile, isFile,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }

        return totalSize
    }

    private func fileModDate(path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    // MARK: - Purgeable Space Helpers

    struct SnapshotInfo {
        let name: String
        let size: Int64
        let date: Date?
    }

    /// Get local Time Machine snapshots and their sizes
    private func getLocalSnapshots() -> [SnapshotInfo] {
        var snapshots: [SnapshotInfo] = []

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            // Parse snapshot names (format: com.apple.TimeMachine.2026-04-08-123456.local)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("TimeMachine") else { continue }

                // Extract date from snapshot name
                var snapshotDate: Date?
                let parts = trimmed.components(separatedBy: ".")
                for part in parts {
                    if let date = dateFormatter.date(from: part) {
                        snapshotDate = date
                        break
                    }
                }

                // Get snapshot size via tmutil
                let sizeBytes = getSnapshotSize(name: trimmed)

                if sizeBytes > 0 {
                    snapshots.append(SnapshotInfo(
                        name: trimmed,
                        size: sizeBytes,
                        date: snapshotDate
                    ))
                }
            }
        } catch {
            // tmutil may require admin privileges
        }

        return snapshots
    }

    /// Get size of a specific local snapshot
    private func getSnapshotSize(name: String) -> Int64 {
        // tmutil doesn't directly report individual snapshot sizes easily
        // Use a reasonable estimate based on total snapshot usage
        // For accurate per-snapshot sizes we'd need root access
        return 0
    }

    // MARK: - App Uninstaller

    /// System app bundle identifiers that should never be uninstalled
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.finder", "com.apple.AppStore",
        "com.apple.systempreferences", "com.apple.Terminal",
        "com.apple.ActivityMonitor", "com.apple.dt.Xcode",
    ]

    /// Scan /Applications for installed apps
    func scanInstalledApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []

        let appDirs = [
            "/Applications",
            "\(home)/Applications",
        ]

        for dir in appDirs {
            guard fileManager.fileExists(atPath: dir),
                  let contents = try? fileManager.contentsOfDirectory(atPath: dir)
            else { continue }

            for item in contents {
                guard item.hasSuffix(".app") else { continue }
                let appPath = (dir as NSString).appendingPathComponent(item)
                let appURL = URL(fileURLWithPath: appPath)

                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier
                else { continue }

                // Skip system/protected apps
                if Self.protectedBundleIDs.contains(bundleID) { continue }
                if appPath.hasPrefix("/System") { continue }

                let appName = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? (item as NSString).deletingPathExtension

                let icon = NSWorkspace.shared.icon(forFile: appPath)
                let appSize = directorySize(path: appPath)

                let associatedFiles = findAssociatedFiles(
                    bundleIdentifier: bundleID,
                    appName: appName
                )

                apps.append(InstalledApp(
                    name: appName,
                    bundleIdentifier: bundleID,
                    path: appPath,
                    icon: icon,
                    appSize: appSize,
                    associatedFiles: associatedFiles
                ))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Find associated files for a given app by bundle identifier and name
    private func findAssociatedFiles(bundleIdentifier: String, appName: String) -> [AssociatedFile] {
        var files: [AssociatedFile] = []

        let searches: [(path: String, kind: AssociatedFileKind)] = [
            ("\(home)/Library/Preferences/\(bundleIdentifier).plist", .preferences),
            ("\(home)/Library/Application Support/\(appName)", .applicationSupport),
            ("\(home)/Library/Application Support/\(bundleIdentifier)", .applicationSupport),
            ("\(home)/Library/Caches/\(bundleIdentifier)", .caches),
            ("\(home)/Library/Saved Application State/\(bundleIdentifier).savedState", .savedState),
            ("\(home)/Library/Containers/\(bundleIdentifier)", .container),
            ("\(home)/Library/HTTPStorages/\(bundleIdentifier)", .webData),
            ("\(home)/Library/WebKit/\(bundleIdentifier)", .webData),
            ("\(home)/Library/Logs/\(appName)", .logs),
            ("\(home)/Library/Logs/\(bundleIdentifier)", .logs),
        ]

        for search in searches {
            guard fileManager.fileExists(atPath: search.path) else { continue }

            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: search.path, isDirectory: &isDir)

            let size: Int64
            if isDir.boolValue {
                size = directorySize(path: search.path)
            } else {
                size = (try? fileManager.attributesOfItem(atPath: search.path)[.size] as? Int64) ?? 0
            }

            guard size > 0 else { continue }

            files.append(AssociatedFile(
                name: URL(fileURLWithPath: search.path).lastPathComponent,
                path: search.path,
                size: size,
                kind: search.kind
            ))
        }

        // Search group containers
        let groupContainersPath = "\(home)/Library/Group Containers"
        if let groupContents = try? fileManager.contentsOfDirectory(atPath: groupContainersPath) {
            for item in groupContents {
                if item.contains(bundleIdentifier) || item.localizedCaseInsensitiveContains(appName) {
                    let fullPath = (groupContainersPath as NSString).appendingPathComponent(item)
                    let size = directorySize(path: fullPath)
                    if size > 0 {
                        files.append(AssociatedFile(
                            name: item,
                            path: fullPath,
                            size: size,
                            kind: .groupContainer
                        ))
                    }
                }
            }
        }

        return files
    }

    /// Calculate total local snapshot size from disk usage difference
    private func getLocalSnapshotSize() -> Int64 {
        // The difference between "Volume Used Space" visible to the filesystem
        // and actual container usage can indicate snapshot overhead.
        // However, without root access, we can only check if tmutil reports snapshots.

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return 0 }

            let snapshotCount = output.components(separatedBy: "\n")
                .filter { $0.contains("TimeMachine") || $0.contains("com.apple") }
                .count

            if snapshotCount == 0 { return 0 }

            // Check if system reports purgeable via newer diskutil
            // On systems that support it, "Purgeable Space" appears in diskutil info
            let diskTask = Process()
            diskTask.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            diskTask.arguments = ["info", "-plist", "/"]
            let diskPipe = Pipe()
            diskTask.standardOutput = diskPipe
            diskTask.standardError = Pipe()
            try diskTask.run()
            diskTask.waitUntilExit()

            let diskData = diskPipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: diskData, format: nil) as? [String: Any],
               let purgeable = plist["APFSContainerFree"] as? Int64,
               let volumeFree = plist["FreeSpace"] as? Int64 {
                // Purgeable is roughly the difference (snapshots that can be freed)
                let purgeableEstimate = max(0, volumeFree - purgeable)
                if purgeableEstimate > 10 * 1024 * 1024 { // Only report if > 10 MB
                    return purgeableEstimate
                }
            }
        } catch {
            // Silently fail
        }

        return 0
    }
}
