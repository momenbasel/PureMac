import SwiftUI
import Combine
import UserNotifications
import AppKit

// InstalledApp is defined in AppInfoFetcher.swift

enum AppSection: Hashable {
    case apps
    case orphans
    case cleaning(CleaningCategory)
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Scan / Clean State

    @Published var selectedCategory: CleaningCategory = .smartScan
    @Published var scanState: ScanState = .idle
    @Published var categoryResults: [CleaningCategory: CategoryResult] = [:]
    @Published var diskInfo = DiskInfo()
    @Published var totalJunkSize: Int64 = 0
    @Published var totalFreedSpace: Int64 = 0
    @Published var scanProgress: Double = 0
    @Published var cleanProgress: Double = 0
    @Published var currentScanCategory: String = ""
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date?
    @Published var deselectedItems: Set<UUID> = []
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false

    // MARK: - App Uninstaller State

    @Published var installedApps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var discoveredFiles: [URL] = []
    @Published var selectedFiles: Set<URL> = []
    @Published var orphanedFiles: [URL] = []
    @Published var isSearchingOrphans: Bool = false
    @Published var isLoadingApps: Bool = false
    @Published var isScanningAppFiles: Bool = false
    @Published var removalError: String?

    // MARK: - Services

    var scheduler = SchedulerService()
    private let scanEngine = ScanEngine()
    private let cleaningEngine = CleaningEngine()

    // MARK: - Computed

    var totalItemCount: Int {
        categoryResults.values.reduce(0) { $0 + $1.itemCount }
    }

    var currentCategoryResult: CategoryResult? {
        categoryResults[selectedCategory]
    }

    var allResults: [CategoryResult] {
        CleaningCategory.scannable.compactMap { categoryResults[$0] }.filter { $0.totalSize > 0 }
    }

    var totalSelectedSize: Int64 {
        allResults.flatMap { $0.items }.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    // MARK: - Init

    init() {
        loadDiskInfo()
        checkFullDiskAccess()
        loadInstalledApps()
        scheduler.setTrigger { [weak self] in
            await self?.runScheduledScan()
        }
        // Only arm the scheduler once onboarding has completed. Before the
        // first launch the defaults plist may have been attacker-planted with
        // autoClean=true - waiting for onboarding ensures a human consents to
        // auto-clean before we start honoring it.
        if UserDefaults.standard.bool(forKey: "PureMac.OnboardingComplete") {
            scheduler.start()
        }
    }

    // MARK: - App Loading

    func loadInstalledApps() {
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = AppInfoFetcher.shared.fetchInstalledApps()
            await MainActor.run { [weak self] in
                self?.installedApps = apps
                self?.isLoadingApps = false
            }
        }
    }

    func scanForAppFiles(_ app: InstalledApp) {
        discoveredFiles = []
        selectedFiles = []
        isScanningAppFiles = true
        let locations = Locations()
        let appInfo = AppPathFinder.AppInfo(
            appName: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            path: app.path,
            entitlements: nil,
            teamIdentifier: nil
        )
        let finder = AppPathFinder(appInfo: appInfo, locations: locations)
        finder.findPathsAsync { [weak self] urls in
            guard let self else { return }
            let sorted = urls.sorted { $0.path < $1.path }
            self.discoveredFiles = sorted
            self.selectedFiles = urls
            self.isScanningAppFiles = false
        }
    }

    func removeSelectedFiles() {
        // Safety guard: never allow a high-risk home dotpath (listed in
        // Conditions.swift) to be sent to trashViaFinder no matter how it
        // ended up in the selection. Catches selection-time additions that
        // slipped past the scanner-side filters.
        let allURLs = Array(selectedFiles)
        let (urls, blocked): ([URL], [URL]) = allURLs.reduce(into: ([], [])) { acc, url in
            let resolved = url.resolvingSymlinksInPath().path
            let isBlocked = highRiskHomeDotPaths.contains { root in
                resolved == root || resolved.hasPrefix(root + "/")
            }
            if isBlocked {
                acc.1.append(url)
            } else {
                acc.0.append(url)
            }
        }
        removalError = nil
        if !blocked.isEmpty {
            let blockedList = blocked.map(\.path).joined(separator: ", ")
            Logger.shared.log("Refused to delete \(blocked.count) high-risk home dotpath(s): \(blockedList)", level: .warning)
            selectedFiles.subtract(blocked)
        }
        guard !urls.isEmpty else {
            if !blocked.isEmpty {
                removalError = "Refused to delete \(blocked.count) protected item(s) (home credential directory or similar)."
            }
            return
        }
        trashViaFinder(urls: urls) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                // Check which files were actually removed from disk
                let removed = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
                if !removed.isEmpty {
                    self.discoveredFiles.removeAll { removed.contains($0) }
                    self.selectedFiles.subtract(removed)
                    Logger.shared.log("Removed \(removed.count) files via Finder", level: .info)
                    self.removeDeletedAppsFromList(removedURLs: removed)
                }

                let failedURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                if failedURLs.isEmpty { return }

                // Fallback: try removing failed files with administrator privileges
                Logger.shared.log("Attempting admin-privileged removal for \(failedURLs.count) files", level: .info)
                DispatchQueue.global(qos: .userInitiated).async {
                    let adminSuccess = self.removeWithAdminPrivileges(failedURLs)
                    DispatchQueue.main.async {
                        let adminRemoved = failedURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
                        if !adminRemoved.isEmpty {
                            self.discoveredFiles.removeAll { adminRemoved.contains($0) }
                            self.selectedFiles.subtract(adminRemoved)
                            Logger.shared.log("Removed \(adminRemoved.count) files with admin privileges", level: .info)
                            self.removeDeletedAppsFromList(removedURLs: adminRemoved)
                        }

                        let finalFailed = failedURLs.count - adminRemoved.count
                        if finalFailed > 0 {
                            if adminSuccess {
                                self.removalError = "\(finalFailed) file\(finalFailed == 1 ? "" : "s") could not be removed. The file may be protected by System Integrity Protection (SIP) or currently in use."
                            } else {
                                self.removalError = "\(finalFailed) file\(finalFailed == 1 ? "" : "s") could not be removed. Grant Full Disk Access in System Settings → Privacy & Security, or the file may be protected by SIP."
                            }
                            Logger.shared.log("Failed to remove \(finalFailed) files after admin fallback", level: .error)
                        }
                    }
                }
            }
        }
    }

    /// Uses Finder via AppleScript to move files to Trash.
    /// This triggers the standard macOS authorization prompt for protected files.
    private func trashViaFinder(urls: [URL], completion: @escaping (Bool) -> Void) {
        let posixPaths = urls.map { "\"\($0.path)\"" }.joined(separator: ", ")
        let script = """
        tell application "Finder"
            set theFiles to {}
            repeat with p in {\(posixPaths)}
                set end of theFiles to (POSIX file p as alias)
            end repeat
            delete theFiles
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var errorInfo: NSDictionary?
            appleScript?.executeAndReturnError(&errorInfo)
            let success = errorInfo == nil
            if let errorInfo {
                Logger.shared.log("Finder trash error: \(errorInfo)", level: .error)
            }
            completion(success)
        }
    }

    /// Attempts to delete files using administrator privileges via AppleScript.
    /// Used as a fallback when Finder trash or FileManager fails due to permission errors.
    private func removeWithAdminPrivileges(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }

        let quotedPaths = urls.map { url in
            "'\(url.path.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
        }
        let shellCommand = "rm -rf -- \(quotedPaths.joined(separator: " "))"
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                Logger.shared.log("Admin remove failed with exit code \(process.terminationStatus)", level: .error)
                return false
            }
            return true
        } catch {
            Logger.shared.log("Admin remove error: \(error)", level: .error)
            return false
        }
    }

    /// Removes apps from the installed list whose .app bundle was deleted.
    private func removeDeletedAppsFromList(removedURLs: [URL]) {
        let removedPaths = Set(removedURLs.map { $0.resolvingSymlinksInPath().path })
        let appsToRemove = installedApps.filter { removedPaths.contains($0.path.resolvingSymlinksInPath().path) }
        if appsToRemove.isEmpty { return }

        for app in appsToRemove {
            installedApps.removeAll { $0.id == app.id }
            if selectedApp?.id == app.id {
                selectedApp = nil
                discoveredFiles = []
                selectedFiles = []
            }
        }
        Logger.shared.log("Removed \(appsToRemove.count) app(s) from installed list", level: .info)
    }

    func findOrphans() {
        isSearchingOrphans = true
        orphanedFiles = []
        Task.detached(priority: .userInitiated) {
            let locations = Locations()
            let knownApps = await MainActor.run { self.installedApps }
            let knownIDs = Set(knownApps.map { $0.bundleIdentifier.normalizedForMatching() })
            let knownNames = Set(knownApps.map { $0.appName.normalizedForMatching() })

            var orphans: [URL] = []
            let fm = FileManager.default

            for path in locations.reverseSearch.paths {
                guard let contents = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for item in contents {
                    let normalized = item.normalizedForMatching()

                    // Skip known system items
                    if skipReverse.contains(where: { normalized.hasPrefix($0) }) { continue }

                    // Check if this item belongs to any known app
                    let belongsToApp = knownIDs.contains(where: { normalized.contains($0) }) ||
                                       knownNames.contains(where: { normalized.contains($0) })

                    if !belongsToApp {
                        let fullPath = URL(fileURLWithPath: path).appendingPathComponent(item)
                        if OrphanSafetyPolicy.isSafeCandidate(fullPath) {
                            orphans.append(fullPath)
                        }
                    }
                }
            }

            let sorted = orphans.sorted { $0.lastPathComponent < $1.lastPathComponent }
            await MainActor.run { [weak self] in
                self?.orphanedFiles = sorted
                self?.isSearchingOrphans = false
            }
        }
    }

    // MARK: - Selection

    func isItemSelected(_ item: CleanableItem) -> Bool {
        !deselectedItems.contains(item.id)
    }

    func toggleItem(_ item: CleanableItem) {
        if deselectedItems.contains(item.id) {
            deselectedItems.remove(item.id)
        } else {
            deselectedItems.insert(item.id)
        }
    }

    func selectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            deselectedItems.remove(item.id)
        }
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            deselectedItems.insert(item.id)
        }
    }

    func selectedSizeInCategory(_ category: CleaningCategory) -> Int64 {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    func selectedCountInCategory(_ category: CleaningCategory) -> Int {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.count
    }

    // MARK: - Helper Methods

    func categorySize(for category: CleaningCategory) -> String {
        guard let result = categoryResults[category], result.totalSize > 0 else { return "" }
        return result.formattedSize
    }

    func categoryBinding(for category: CleaningCategory) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                guard let self else { return false }
                return self.selectedCountInCategory(category) > 0
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue {
                    self.selectAllInCategory(category)
                } else {
                    self.deselectAllInCategory(category)
                }
            }
        )
    }

    func itemBinding(for item: CleanableItem) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.isItemSelected(item) ?? false
            },
            set: { [weak self] _ in
                self?.toggleItem(item)
            }
        )
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        Task.detached {
            let granted = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { [weak self] in
                self?.hasFullDiskAccess = granted
            }
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
    }

    // MARK: - Disk Info

    func loadDiskInfo() {
        Task {
            let info = await scanEngine.getDiskInfo()
            self.diskInfo = info
        }
    }

    // MARK: - Scanning

    func startSmartScan() {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: "Preparing...")
        categoryResults = [:]
        totalJunkSize = 0
        scanProgress = 0
        deselectedItems.removeAll()

        Task {
            let categories = CleaningCategory.scannable
            let total = categories.count

            for (index, category) in categories.enumerated() {
                let progress = Double(index) / Double(total)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)

                let result = await scanEngine.scanCategory(category)
                categoryResults[category] = result
                totalJunkSize += result.totalSize
            }

            scanProgress = 1.0
            scanState = .completed
            loadDiskInfo()
        }
    }

    func scanSingleCategory(_ category: CleaningCategory) {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: category.rawValue)
        scanProgress = 0

        Task {
            scanProgress = 0.5
            deselectedItems.removeAll()
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result

            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            scanProgress = 1.0
            scanState = .completed
        }
    }

    // MARK: - Cleaning

    func cleanAll() {
        guard !scanState.isActive else { return }

        let itemsToClean = allResults.flatMap { $0.items }.filter { isItemSelected($0) }
        guard !itemsToClean.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            let result = await cleaningEngine.cleanItems(itemsToClean) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            totalFreedSpace = result.freedSpace
            lastCleanedDate = Date()

            categoryResults = [:]
            totalJunkSize = 0
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    func cleanCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category], !scanState.isActive else { return }

        let selectedItems = result.items.filter { isItemSelected($0) }
        guard !selectedItems.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            let cleanResult = await cleaningEngine.cleanItems(selectedItems) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            totalFreedSpace = cleanResult.freedSpace
            lastCleanedDate = Date()

            categoryResults.removeValue(forKey: category)
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    // MARK: - Purgeable

    func purgePurgeable() {
        guard !scanState.isActive else { return }

        scanState = .cleaning(progress: 0)

        Task {
            scanState = .cleaning(progress: 0.5)
            let freed = await cleaningEngine.purgePurgeableSpace()
            totalFreedSpace = freed
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    // MARK: - Scheduled Scan

    private func runScheduledScan() async {
        let categories = scheduler.config.categoriesToScan
        var totalFound: Int64 = 0

        for category in categories {
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result
            totalFound += result.totalSize
        }

        totalJunkSize = totalFound

        if scheduler.config.autoClean && totalFound >= scheduler.config.minimumCleanSize {
            cleanAll()
        }

        if scheduler.config.autoPurge {
            _ = await cleaningEngine.purgePurgeableSpace()
        }

        if scheduler.config.notifyOnCompletion {
            sendNotification(freed: totalFound)
        }
    }

    private func sendNotification(freed: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "PureMac"
        let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        content.body = String(format: NSLocalizedString("Found %@ of junk files.", comment: ""), sizeStr)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
