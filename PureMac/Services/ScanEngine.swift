import Foundation

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
            Logger.shared.log("Disk info unavailable: \(error.localizedDescription)", level: .warning)
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
        // Only exclude Homebrew since it has its own dedicated scan category
        let excludedRootPaths = Set([
            "\(home)/Library/Caches/Homebrew",
        ].map(normalizePath))

        // Dynamically enumerate ~/Library/Caches/ so every subdirectory is visible
        let cachePath = "\(home)/Library/Caches"
        let scanned = scanDirectory(
            path: cachePath,
            category: .userCache,
            recursive: false,
            maxDepth: 1,
            excluding: excludedRootPaths
        )
        items.append(contentsOf: scanned)

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

        // Default Homebrew download cache
        var brewCachePaths = [
            "\(home)/Library/Caches/Homebrew",
        ]

        // Detect custom HOMEBREW_CACHE via `brew --cache`
        let brewBinPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        var detectedCustomCache = false
        for brewBin in brewBinPaths {
            guard fileManager.fileExists(atPath: brewBin) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brewBin)
            task.arguments = ["--cache"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    let normalized = normalizePath(output)
                    if !brewCachePaths.map(normalizePath).contains(normalized) {
                        brewCachePaths.append(output)
                    }
                    detectedCustomCache = true
                }
            } catch {
                Logger.shared.log("Failed to run \(brewBin) --cache: \(error.localizedDescription)", level: .warning)
            }
            break // Only need the first available brew binary
        }

        if !detectedCustomCache {
            Logger.shared.log("Homebrew not found at standard paths; scanning default cache location only", level: .info)
        }

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
            Logger.shared.log("Cannot enumerate \(path): \(error.localizedDescription)", level: .warning)
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
            Logger.shared.log("tmutil listlocalsnapshots failed: \(error.localizedDescription)", level: .info)
        }

        return snapshots
    }

    /// Get size of a specific local snapshot via APFS snapshot listing
    private func getSnapshotSize(name: String) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "listSnapshots", "/", "-plist"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let snapshots = plist["Snapshots"] as? [[String: Any]] else {
                Logger.shared.log("Could not parse APFS snapshot plist for \(name)", level: .info)
                return 0
            }

            for snapshot in snapshots {
                if let snapshotName = snapshot["SnapshotName"] as? String,
                   snapshotName == name,
                   let dataSize = snapshot["DataSize"] as? Int64 {
                    return dataSize
                }
            }

            Logger.shared.log("Snapshot \(name) not found in APFS listing", level: .info)
        } catch {
            Logger.shared.log("diskutil apfs listSnapshots failed: \(error.localizedDescription)", level: .warning)
        }

        return 0
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
            Logger.shared.log("Purgeable space detection failed: \(error.localizedDescription)", level: .warning)
        }

        return 0
    }
}
