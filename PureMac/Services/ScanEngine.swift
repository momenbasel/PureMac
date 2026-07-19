import Foundation

actor ScanEngine {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Live path reporter for the dashboard's scanning ticker. Throttled so
    /// a directory with thousands of entries doesn't flood the main actor.
    private var onPath: (@Sendable (String) -> Void)?
    private var lastReport = Date.distantPast

    /// `path` is an autoclosure so the String is only materialized after the
    /// throttle gate passes — a deep home-directory walk enumerates hundreds
    /// of thousands of entries and only ~12/sec are ever displayed.
    private func report(_ path: @autoclosure () -> String) {
        guard let onPath else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        onPath(path())
    }

    private struct CleanupTarget {
        let name: String
        let path: String
        let isSelected: Bool
        let minimumSize: Int64

        init(name: String, path: String, isSelected: Bool = true, minimumSize: Int64 = 1024) {
            self.name = name
            self.path = path
            self.isSelected = isSelected
            self.minimumSize = minimumSize
        }
    }

    // MARK: - Public API

    func scanCategory(
        _ category: CleaningCategory,
        onPath: (@Sendable (String) -> Void)? = nil
    ) async -> CategoryResult {
        self.onPath = onPath
        defer { self.onPath = nil }
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
        case .nodeCache:
            return scanNodeCache()
        case .dockerCache:
            return scanDockerCache()
        case .universalBinaries:
            return scanUniversalBinaries()
        case .languageFiles:
            return scanLanguageFiles()
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

            // Use URLResourceValues for accurate purgeable space detection
            let rootURL = URL(fileURLWithPath: "/")
            let values = try rootURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
               let freeCapacity = values.volumeAvailableCapacity {
                // Purgeable = important capacity (free + purgeable) minus actual free
                let purgeable = importantCapacity - Int64(freeCapacity)
                if purgeable > 10 * 1024 * 1024 { // Only report if > 10 MB
                    info.purgeableSpace = purgeable
                }
            }
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
        // Exclude cache roots claimed by dedicated categories to avoid double-counting.
        let excludedRootPaths = Set([
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Library/Caches/com.electron.ollama",
            "\(home)/Library/Caches/ollama",
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

        // Sandboxed apps keep their caches inside per-app containers, not
        // ~/Library/Caches — on modern macOS this is where most of the
        // "user cache" gigabytes actually live. One item per container,
        // skipping near-empty caches (< 1 MB).
        let containerRoots = [
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
        ]
        for root in containerRoots {
            guard let containers = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            // App containers nest caches under Data/; group containers don't.
            let cacheSubpath = root.hasSuffix("Group Containers")
                ? "Library/Caches"
                : "Data/Library/Caches"
            for container in containers {
                let cachePath = (root as NSString)
                    .appendingPathComponent(container)
                    .appending("/" + cacheSubpath)
                // Same symlink defense as scanDirectory: an app at this UID
                // could plant Data or Data/Library as a symlink into an
                // allow-listed root and have the target sized here and later
                // deleted. Only accept paths that resolve to themselves.
                let resolvedCachePath = URL(fileURLWithPath: cachePath).resolvingSymlinksInPath().path
                guard normalizePath(resolvedCachePath) == normalizePath(cachePath) else { continue }
                if let item = makeCleanupItem(
                    name: "\(container) (sandbox cache)",
                    path: cachePath,
                    category: .userCache,
                    minimumSize: 1024 * 1024
                ) {
                    items.append(item)
                }
            }
        }

        // Per-app HTTP cookie/response storage — one entry per app, same
        // non-recursive shape as the top-level Caches pass above. CFNetwork
        // keeps each native app's cookies and HSTS state here, i.e. live
        // login sessions rather than regenerable cache, so these entries
        // start unselected and the user opts in per app.
        let httpStorages = scanDirectory(
            path: "\(home)/Library/HTTPStorages",
            category: .userCache,
            recursive: false,
            maxDepth: 1,
            isSelected: false
        )
        items.append(contentsOf: httpStorages)

        let uniqueItems = deduplicatedItems(items)
        let totalSize = uniqueItems.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .userCache, items: uniqueItems, totalSize: totalSize)
    }

    private func scanAIApps() -> CategoryResult {
        let targets = [
            CleanupTarget(
                name: String(localized: "Ollama Logs"),
                path: "\(home)/.ollama/logs"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Cache"),
                path: "\(home)/Library/Caches/ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Electron Cache"),
                path: "\(home)/Library/Caches/com.electron.ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama WebKit Data"),
                path: "\(home)/Library/WebKit/com.electron.ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Saved State"),
                path: "\(home)/Library/Saved Application State/com.electron.ollama.savedState"
            ),
            CleanupTarget(
                name: String(localized: "Ollama CLI Prompt History (Optional)"),
                path: "\(home)/.ollama/history",
                isSelected: false,
                minimumSize: 0
            ),
            CleanupTarget(
                name: String(localized: "LM Studio Server Logs"),
                path: "\(home)/.lmstudio/server-logs"
            ),
            CleanupTarget(
                name: String(localized: "LM Studio Conversations (Optional)"),
                path: "\(home)/.lmstudio/conversations",
                isSelected: false,
                minimumSize: 0
            ),
        ]

        let items = deduplicatedItems(targets.compactMap { target in
            makeCleanupItem(
                name: target.name,
                path: target.path,
                category: .aiApps,
                isSelected: target.isSelected,
                minimumSize: target.minimumSize
            )
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

        // Honor the thresholds the user set in Settings → Cleaning. These keys
        // were previously surfaced in the UI but never read here, so the sliders
        // did nothing; defaults match the old hardcoded 100 MB / 12-month values.
        let defaults = UserDefaults.standard
        let thresholdMB = defaults.object(forKey: "settings.cleaning.largeFileThreshold") as? Int ?? 100
        let oldFileMonths = defaults.object(forKey: "settings.cleaning.oldFileMonths") as? Int ?? 12
        let minSize = Int64(max(1, thresholdMB)) * 1024 * 1024
        let oldCutoff = Calendar.current.date(byAdding: .month, value: -max(1, oldFileMonths), to: Date())
            ?? Date.distantPast

        // Folders the user excluded from the large-file scan (issue #121) —
        // e.g. VM images, media libraries, project assets they never want
        // surfaced. Files anywhere inside an excluded folder are skipped, and
        // the directory subtree is pruned so we don't even walk it.
        let excludedFolders = (defaults.stringArray(forKey: "settings.cleaning.largeFileExcludedFolders") ?? [])
            .map(normalizePath)
            .filter { !$0.isEmpty }

        // Honor the "Skip hidden files during scan" toggle, which was a dead
        // control until now (no scanner read it). Default true preserves the
        // previous always-skip behavior.
        let skipHidden = defaults.object(forKey: "settings.cleaning.skipHiddenFiles") as? Bool ?? true
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if skipHidden { enumerationOptions.insert(.skipsHiddenFiles) }

        func isExcluded(_ path: String) -> Bool {
            let normalized = normalizePath(path)
            return excludedFolders.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
        }

        let searchPaths = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
        ]

        for basePath in searchPaths {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: enumerationOptions
            ) else { continue }

            // No entry cap. A 5k cap was here previously and meant any user
            // with hundreds of thousands of small files (e.g. node_modules
            // checkouts) would never see anything past entry 5k — the
            // scattered 100+ MB files were always past that bound.
            for case let fileURL as URL in enumerator {
                // Prune excluded subtrees: hitting the excluded directory itself
                // skips its whole contents; for files the call is a harmless no-op.
                // Skip the path normalization entirely when nothing is excluded.
                if !excludedFolders.isEmpty, isExcluded(fileURL.path) {
                    enumerator.skipDescendants()
                    continue
                }
                report(fileURL.path)
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      let isFile = resourceValues.isRegularFile, isFile,
                      let fileSize = resourceValues.fileSize
                else { continue }

                let size = Int64(fileSize)
                let modDate = resourceValues.contentModificationDate

                if size > minSize || (modDate != nil && modDate! < oldCutoff && size > 10 * 1024 * 1024) {
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

        // Detect APFS purgeable space via URLResourceValues (no admin needed)
        let diskInfo = getDiskInfo()
        if diskInfo.purgeableSpace > 0 {
            // Purgeable space is reclaimed via `diskutil apfs purgePurgeable /`
            // (see CleaningEngine.purgePurgeableSpace), it is NOT a file that
            // gets unlinked. Using "/" as the path made the UI render the root
            // directory as the deletion target and triggered a bogus
            // "couldn't remove /" error after cleaning. Use an empty path so
            // the row shows no misleading filesystem location and the reveal-
            // in-Finder action stays disabled for this entry. (See issue #112.)
            items.append(CleanableItem(
                name: "APFS Purgeable Space",
                path: "",
                size: diskInfo.purgeableSpace,
                category: .purgeableSpace,
                isSelected: true,
                lastModified: nil
            ))
            totalSize = diskInfo.purgeableSpace
        }

        // Also list Time Machine local snapshots if any exist
        let snapshots = getLocalSnapshots()
        for snapshot in snapshots {
            let snapshotSize = snapshot.size > 0 ? snapshot.size : 0
            if snapshotSize > 0 {
                items.append(CleanableItem(
                    name: "TM Snapshot: \(snapshot.name)",
                    path: snapshot.name,
                    size: snapshotSize,
                    category: .purgeableSpace,
                    isSelected: false,
                    lastModified: snapshot.date
                ))
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
            // Per-OS symbol caches, regenerated on next device connect.
            // These alone are often tens of GB on active dev machines.
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            // Simulator clones spun up by xcodebuild test runs
            "\(home)/Library/Developer/XCTestDevices",
            // SwiftUI preview build products
            "\(home)/Library/Developer/Xcode/UserData/Previews",
            // Swift Package Manager download + build caches
            "\(home)/Library/Caches/org.swift.swiftpm",
            "\(home)/Library/org.swift.swiftpm",
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

        // Known-good Homebrew cache roots. Any path returned by `brew --cache`
        // that is NOT inside one of these is refused - prevents an attacker
        // setting HOMEBREW_CACHE=$HOME/Documents from steering our cleanup.
        let knownBrewRoots = [
            "\(home)/Library/Caches/Homebrew",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            "/Library/Caches/Homebrew",
        ]

        // Detect custom HOMEBREW_CACHE via `brew --cache`. Strip HOMEBREW_*
        // from the child env so an attacker can't steer the output via
        // launchctl setenv, then validate the output against knownBrewRoots.
        let brewBinPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        var detectedCustomCache = false
        for brewBin in brewBinPaths {
            guard fileManager.fileExists(atPath: brewBin) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brewBin)
            task.arguments = ["--cache"]
            var sanitizedEnv = ProcessInfo.processInfo.environment
            for key in Array(sanitizedEnv.keys) where key.hasPrefix("HOMEBREW_") {
                sanitizedEnv.removeValue(forKey: key)
            }
            task.environment = sanitizedEnv
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
                    let isKnown = knownBrewRoots.contains { root in
                        normalized == root || normalized.hasPrefix(root + "/")
                    }
                    guard isKnown else {
                        Logger.shared.log("Refusing suspicious brew cache path: \(output)", level: .warning)
                        break
                    }
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

    private func scanNodeCache() -> CategoryResult {
        // Each entry is `(displayName, defaultPath, optional CLI for cache-dir
        // detection)`. The CLI invocation overrides `defaultPath` if the user
        // has set a custom location (e.g. via `npm config set cache`).
        struct ManagerCache {
            let name: String
            let defaultPath: String
            let detectionCommand: (cli: String, args: [String])?
        }

        let managers: [ManagerCache] = [
            ManagerCache(
                name: String(localized: "npm cache"),
                defaultPath: "\(home)/.npm",
                detectionCommand: (cli: "npm", args: ["config", "get", "cache"])
            ),
            ManagerCache(
                name: String(localized: "yarn classic cache"),
                defaultPath: "\(home)/Library/Caches/Yarn",
                detectionCommand: (cli: "yarn", args: ["cache", "dir"])
            ),
            // Yarn Berry / v2+ uses a per-project .yarn/cache. We don't try to
            // chase those — they're inside user projects and shouldn't be
            // touched by a system cleaner. The classic cache above remains the
            // global, safe-to-clean location.
            ManagerCache(
                name: String(localized: "pnpm content-addressable store"),
                defaultPath: "\(home)/Library/pnpm/store",
                detectionCommand: (cli: "pnpm", args: ["store", "path"])
            ),
        ]

        var items: [CleanableItem] = []

        // Common $PATH locations on macOS where these CLIs land.
        let cliSearchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node",
        ]

        for manager in managers {
            var paths: [String] = []
            paths.append(manager.defaultPath)

            if let cmd = manager.detectionCommand,
               let cliPath = locateExecutable(named: cmd.cli, searchPaths: cliSearchPaths),
               let detected = runCommandReadingStdout(executable: cliPath, args: cmd.args) {
                let normalized = detected.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty,
                   !paths.map(normalizePath).contains(normalizePath(normalized)) {
                    paths.append(normalized)
                }
            }

            for path in paths {
                guard fileManager.fileExists(atPath: path) else { continue }
                let size = directorySize(path: path)
                guard size > 0 else { continue }
                items.append(CleanableItem(
                    name: manager.name,
                    path: path,
                    size: size,
                    category: .nodeCache,
                    isSelected: true,
                    lastModified: nil
                ))
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .nodeCache, items: items, totalSize: totalSize)
    }

    // -- Process helpers (used by scanNodeCache) --

    private func locateExecutable(named name: String, searchPaths: [String]) -> String? {
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
            // For nvm: ~/.nvm/versions/node/<version>/bin/<name>
            if dir.hasSuffix("/.nvm/versions/node"),
               let versions = try? fileManager.contentsOfDirectory(atPath: dir) {
                for v in versions {
                    let nested = (dir as NSString).appendingPathComponent("\(v)/bin/\(name)")
                    if fileManager.isExecutableFile(atPath: nested) {
                        return nested
                    }
                }
            }
        }
        return nil
    }

    private func runCommandReadingStdout(executable: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger.shared.log("\(executable) \(args.joined(separator: " ")) failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func scanDockerCache() -> CategoryResult {
        var items: [CleanableItem] = []

        // Docker Desktop on macOS keeps its VM disk + caches under
        // ~/Library/Containers/com.docker.docker/Data. The caches we
        // surface here are *recoverable* — they will be regenerated by
        // Docker on next pull/build, and `docker system prune` is the
        // CLI equivalent of cleaning them.
        let dockerDataDirs = [
            // Build cache (BuildKit), per-user
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            // Vmnetd / vpnkit log + telemetry caches
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            // Group containers caches (Docker Desktop helper apps)
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            // CLI plugin download cache
            "\(home)/.docker/cli-plugins/.cache",
            // Buildx / containerd inline cache
            "\(home)/.docker/buildx/cache",
            // OrbStack (Docker Desktop alternative) keeps its daemon logs and
            // caches outside ~/Library/Containers. The VM data disk itself
            // (~/.orbstack/data) is intentionally NOT listed — image/container
            // space inside the VM is only reclaimable via `docker system
            // prune`, surfaced as the virtual entry below.
            "\(home)/.orbstack/log",
            "\(home)/Library/Caches/dev.kdrag0n.MacVirt",
            "\(home)/Library/Logs/OrbStack",
        ]

        for path in dockerDataDirs {
            guard fileManager.fileExists(atPath: path) else { continue }
            let size = directorySize(path: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: size,
                category: .dockerCache,
                isSelected: true,
                lastModified: nil
            ))
        }

        // If the `docker` CLI is available and the daemon answers, surface
        // reclaimable space reported by `docker system df` as a single
        // virtual entry. Cleaning it runs `docker system prune -f` (see
        // CleaningEngine.pruneDockerSystem) — stopped containers, dangling
        // images, unused networks, and build cache; running containers and
        // tagged images are untouched. The empty path mirrors the purgeable-
        // space convention: this is an action, not a file unlink, so the UI
        // must not offer reveal-in-Finder or attempt removeItem on it.
        // Works for both Docker Desktop and OrbStack (both ship a docker CLI
        // at these locations).
        let dockerBinPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        for dockerBin in dockerBinPaths where fileManager.fileExists(atPath: dockerBin) {
            if let reclaimable = reclaimableDockerSpace(dockerBin: dockerBin), reclaimable > 0 {
                items.append(CleanableItem(
                    name: String(localized: "Docker prune (stopped containers, dangling images, build cache)"),
                    path: "",
                    size: reclaimable,
                    category: .dockerCache,
                    isSelected: false,
                    lastModified: nil
                ))
            }
            break
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .dockerCache, items: items, totalSize: totalSize)
    }

    private func scanUniversalBinaries() -> CategoryResult {
        var items: [CleanableItem] = []

        // One item per app bundle. The item path is the BUNDLE path (not the
        // executable) so reveal-in-Finder works; CleaningEngine re-derives
        // the per-binary lipo work list from that path via BinaryThinner.
        // Every finding starts unselected: thinning replaces the app's
        // Developer ID signature with an ad-hoc one (auto-update and
        // keychain impact), so it is per-app opt-in, never part of a
        // default Clean All.
        let findings = UniversalBinaryScanner().scan()
        for finding in findings {
            report(finding.appPath)
            items.append(CleanableItem(
                name: "\(finding.appName) (\(finding.removableArchs.joined(separator: ", ")))",
                path: finding.appPath,
                size: finding.reclaimableBytes,
                category: .universalBinaries,
                isSelected: false,
                lastModified: fileModDate(path: finding.appPath)
            ))
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .universalBinaries, items: items, totalSize: totalSize)
    }

    private func scanLanguageFiles() -> CategoryResult {
        // One item per removable .lproj so the user can keep individual
        // languages. Every finding starts unselected: removal re-signs the
        // bundle ad-hoc (see BinaryThinner), so stripping localizations is
        // per-app opt-in, never part of a default Clean All.
        let scanner = LanguageFilesScanner()
        let findings = scanner.scan(applicationDirs: ["/Applications", "\(home)/Applications"])
        let items = scanner.flatten(findings).map { entry in
            report(entry.path)
            return CleanableItem(
                name: entry.name,
                path: entry.path,
                size: entry.size,
                category: .languageFiles,
                isSelected: false,
                lastModified: nil
            )
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .languageFiles, items: items, totalSize: totalSize)
    }

    /// Sum the reclaimable bytes reported by `docker system df --format json`.
    /// Returns nil when Docker isn't running or the command fails — callers
    /// should treat that as "no reclaimable info available", not as an error.
    private func reclaimableDockerSpace(dockerBin: String) -> Int64? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: dockerBin)
        task.arguments = ["system", "df", "--format", "{{.Reclaimable}}"]
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger.shared.log("docker system df failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // Each line looks like e.g. "1.234GB (45%)" — parse the leading number.
        var total: Int64 = 0
        for line in output.split(separator: "\n") {
            let raw = line.split(separator: " ").first.map(String.init) ?? ""
            if let bytes = parseHumanBytes(raw) {
                total += bytes
            }
        }
        return total
    }

    /// Parse Docker's compact size format ("1.23GB", "456MB", "789kB") into bytes.
    private func parseHumanBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        for (suffix, multiplier) in units {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let value = Double(numberPart) {
                    return Int64(value * multiplier)
                }
            }
        }
        return nil
    }
    // MARK: - Helpers

    private func scanDirectory(
        path: String,
        category: CleaningCategory,
        recursive: Bool,
        maxDepth: Int,
        isSelected: Bool = true,
        excluding excludedPaths: Set<String> = []
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []

        guard fileManager.fileExists(atPath: path),
              fileManager.isReadableFile(atPath: path) else { return [] }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for item in contents {
                if Task.isCancelled { break }
                let fullPath = (path as NSString).appendingPathComponent(item)
                report(fullPath)
                if excludedPaths.contains(normalizePath(fullPath)) {
                    continue
                }

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

                // Security: skip symlinks to prevent symlink-following attacks
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let fileType = attrs[.type] as? FileAttributeType,
                   fileType == .typeSymbolicLink {
                    continue
                }

                // Skip SIP-protected/immutable entries — they fail even
                // admin rm and only produce "Couldn't clean everything"
                // alerts (e.g. /private/var/log/wifi.log).
                if FileProtection.isProtectedFromDeletion(path: fullPath) {
                    continue
                }

                if isDir.boolValue {
                    let size = directorySize(path: fullPath)
                    if size > 1024 { // Skip tiny entries
                        items.append(CleanableItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: isSelected,
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
                            isSelected: isSelected,
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

    private func makeCleanupItem(
        name: String,
        path: String,
        category: CleaningCategory,
        isSelected: Bool = true,
        minimumSize: Int64 = 1024
    ) -> CleanableItem? {
        report(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: path) else { return nil }

        if isDirectory.boolValue {
            let size = directorySize(path: path)
            guard size > minimumSize else { return nil }
            return CleanableItem(
                name: name,
                path: path,
                size: size,
                category: category,
                isSelected: isSelected,
                lastModified: fileModDate(path: path)
            )
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size > minimumSize else { return nil }

        return CleanableItem(
            name: name,
            path: path,
            size: size,
            category: category,
            isSelected: isSelected,
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

        // errorHandler returns true so unreadable entries are skipped
        // instead of aborting the walk partway through the tree.
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        // No entry cap. A 10k cap was here previously and made huge trees
        // like Xcode DerivedData (millions of files) report a fraction of
        // their real size. report() is throttled, so display stays cheap.
        // A DerivedData/DeviceSupport walk can hold this loop for minutes,
        // so honor task cancellation to let an aborted scan stop promptly.
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            report(fileURL.path)
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
                  let isFile = values.isRegularFile, isFile else { continue }
            // Allocated size counts actual on-disk blocks (accurate for
            // sparse/cloned files); fall back to logical size when the
            // volume doesn't report it.
            if let size = values.totalFileAllocatedSize ?? values.fileSize {
                totalSize += Int64(size)
            }
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
