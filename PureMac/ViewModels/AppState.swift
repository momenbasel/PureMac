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

extension Notification.Name {
    /// Posted by the Finder Services handler ("Uninstall with PureMac") with a
    /// `["path": String]` userInfo pointing at the right-clicked .app bundle.
    static let pureMacExternalUninstall = Notification.Name("PureMac.ExternalUninstall")
}

/// Cold-launch buffer for Finder Services. A "Uninstall with PureMac" request
/// can arrive before the SwiftUI scene (and thus AppState) exists; the posted
/// notification then has no subscriber and is lost (NotificationCenter has no
/// replay). AppDelegate stashes the path here and AppState drains it in init.
enum ExternalUninstallBuffer {
    // Written by the Finder Services handler and drained by AppState — both
    // run on the main thread, so a plain static is sufficient here.
    static var pendingPath: String?
}

/// Standalone observable for the live scan-path ticker. The scan engine reports
/// the filesystem path it is touching ~10×/sec. Routing that through AppState's
/// own `@Published` storage republished the *entire* view tree at that rate,
/// which surfaced as window-drag / button-hover lag and a Smart Scan that
/// looked frozen until you switched sidebar sections and forced a fresh render
/// (issues #119, #120). Isolating the high-frequency value here means only the
/// small ticker label observes it, so the rest of the UI stays still.
@MainActor
final class ScanProgressTicker: ObservableObject {
    @Published var path: String = ""
}

@MainActor
final class AppState: ObservableObject {
    typealias AppFileScanner = @MainActor (
        _ app: InstalledApp,
        _ locations: Locations,
        _ completion: @escaping (Set<URL>) -> Void
    ) -> Void

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
    /// Live filesystem path the scan engine is touching, feeding the dashboard's
    /// ticker. Deliberately NOT a `@Published` on AppState — it updates ~10×/sec
    /// and would otherwise invalidate the whole view tree (issues #119, #120).
    /// Only the ticker label observes this object directly.
    let scanTicker = ScanProgressTicker()
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date?
    @Published var selectedCleanupItems: Set<UUID> = []
    @Published var deselectedItems: Set<UUID> = []
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published var cleanError: String?
    /// True when the most recent clean error is rooted in a TCC/FDA refusal
    /// (i.e. items survived even the admin pass). MainWindow uses this to
    /// route the user into the PermissionSheet instead of the generic alert.
    @Published var cleanErrorIsFDAFixable: Bool = false
    /// Items that survived the most recent clean attempt — used to re-run the
    /// operation after the user grants Full Disk Access without forcing them
    /// to re-select anything.
    @Published var pendingPermissionRetryItems: [CleanableItem] = []

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
    @Published var removalNeedsFullDiskAccess = false
    /// Snapshot of the URLs that failed the most recent uninstall due to a
    /// permission denial. Frozen at finishRemoval time so AppFilesView's
    /// retry path operates on the failed batch even if the user clicks a
    /// different app or mutates selection while the FDA sheet is open.
    @Published var lastFailedRemovalURLs: [URL] = []
    @Published var appFileScanLocationCount: Int = 0
    /// Set when a right-clicked app arrives via the Finder Services handler.
    /// MainWindow consumes it on both onChange AND onAppear so a request that
    /// lands before MainWindow mounts (cold launch, or while onboarding is
    /// still showing) is still surfaced — a one-shot token would be missed.
    @Published var pendingExternalApp: InstalledApp?

    private var externalUninstallObserver: AnyCancellable?

    // MARK: - Services

    var scheduler = SchedulerService()
    private let scanEngine = ScanEngine()
    private let cleaningEngine = CleaningEngine()
    private let locationsProvider: () -> Locations
    private let appFileScanner: AppFileScanner

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

    var currentAppFileSearchLocationCount: Int {
        if isScanningAppFiles && appFileScanLocationCount > 0 {
            return appFileScanLocationCount
        }
        return discoveredFiles.count
    }

    // MARK: - Init

    init(
        performStartupTasks: Bool = true,
        locationsProvider: @escaping () -> Locations = Locations.init,
        appFileScanner: @escaping AppFileScanner = AppState.defaultAppFileScanner
    ) {
        self.locationsProvider = locationsProvider
        self.appFileScanner = appFileScanner

        // Listen for right-click "Uninstall with PureMac" hand-offs from the
        // Finder Services handler in AppDelegate.
        externalUninstallObserver = NotificationCenter.default
            .publisher(for: .pureMacExternalUninstall)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let path = (note.userInfo?["path"] as? String) ?? ExternalUninstallBuffer.pendingPath
                ExternalUninstallBuffer.pendingPath = nil
                guard let path else { return }
                Task { @MainActor in self?.presentExternalUninstall(appPath: path) }
            }
        // Drain a request that arrived before this AppState existed (cold launch
        // via Finder Services — the notification fired with no subscriber).
        if let buffered = ExternalUninstallBuffer.pendingPath {
            ExternalUninstallBuffer.pendingPath = nil
            presentExternalUninstall(appPath: buffered)
        }

        if performStartupTasks {
            loadDiskInfo()
            checkFullDiskAccess()
            loadInstalledApps()
            scheduler.setTrigger { [weak self] in
                await self?.runScheduledScan()
            }
            // Only arm the scheduler once onboarding has completed. Before
            // the first launch the defaults plist may have been
            // attacker-planted with autoClean=true; wait for human consent
            // via onboarding.
            if UserDefaults.standard.bool(forKey: "PureMac.OnboardingComplete") {
                scheduler.start()
            }
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

    /// Resolve a right-clicked .app (via the Finder Services handler) into the
    /// uninstaller: select it, kick off the related-files scan, and signal
    /// MainWindow to surface the Installed Apps section.
    func presentExternalUninstall(appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        if let cached = installedApps.first(where: { $0.path.standardizedFileURL == url.standardizedFileURL }) {
            applyExternalUninstall(cached)
            return
        }
        // Not in the cached list (non-standard location, or a cold start before
        // loadInstalledApps finished). Resolve off the main thread — fetchApp
        // walks the entire bundle to size it, which would beachball the UI for
        // a multi-gigabyte app.
        Task.detached(priority: .userInitiated) {
            let app = AppInfoFetcher.shared.fetchApp(at: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let app else {
                    Logger.shared.log("Finder uninstall request rejected (non-app or protected): \(appPath)", level: .warning)
                    return
                }
                self.applyExternalUninstall(app)
            }
        }
    }

    private func applyExternalUninstall(_ app: InstalledApp) {
        selectedApp = app
        pendingExternalApp = app
        scanForAppFiles(app)
    }

    func scanForAppFiles(_ app: InstalledApp) {
        discoveredFiles = []
        selectedFiles = []
        isScanningAppFiles = true
        let locations = locationsProvider()
        appFileScanLocationCount = locations.appSearch.paths.count
        appFileScanner(app, locations) { [weak self] urls in
            guard let self else { return }
            let sorted = urls.sorted { $0.path < $1.path }
            self.discoveredFiles = sorted
            self.selectedFiles = urls
            self.isScanningAppFiles = false
            self.appFileScanLocationCount = 0
        }
    }

    func removeSelectedFiles() {
        // Re-entrance guard: if a previous removal is still resolving and
        // the FDA sheet/retry hasn't finished, a second call would race-
        // overwrite `lastFailedRemovalURLs` before the first batch's retry
        // closure read it. We can't gate on `removalNeedsFullDiskAccess`
        // alone — AppFilesView clears that flag the moment it hands off to
        // the coordinator, leaving a window where a second remove call
        // would pass the guard while the coordinator is still polling.
        // PermissionCoordinator.isRequesting covers the full sheet-open +
        // retry-pending span.
        guard !removalNeedsFullDiskAccess,
              !PermissionCoordinator.shared.isRequesting else {
            Logger.shared.log("Refused duplicate removeSelectedFiles while FDA flow is active", level: .info)
            return
        }
        // Safety guard: never allow a high-risk home dotpath (listed in
        // Conditions.swift) to be trashed no matter how it ended up in the
        // selection. Catches selection-time additions that slipped past the
        // scanner-side filters.
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
        removalNeedsFullDiskAccess = false
        if !blocked.isEmpty {
            let blockedList = blocked.map(\.path).joined(separator: ", ")
            Logger.shared.log("Refused to delete \(blocked.count) high-risk home dotpath(s): \(blockedList)", level: .warning)
            selectedFiles.subtract(blocked)
        }
        guard !urls.isEmpty else {
            if !blocked.isEmpty {
                removalError = String(
                    format: String(localized: "Protected items were not deleted: %lld."),
                    Int64(blocked.count)
                )
            }
            return
        }
        trashDirectly(urls: urls) { [weak self] removed, needsFullDiskAccess, needsAdmin, failed in
            Task { @MainActor in
                guard let self else { return }

                self.applyRemovedAppFiles(removed)

                guard !needsAdmin.isEmpty else {
                    self.finishRemoval(
                        removedAny: !removed.isEmpty,
                        needsFullDiskAccess: needsFullDiskAccess,
                        attemptedAdmin: false,
                        failed: failed,
                        adminError: nil
                    )
                    return
                }

                let items = needsAdmin.map { self.cleanableUninstallItem(for: $0) }
                let adminResult = await self.cleaningEngine.cleanWithAdminPrivileges(items: items)
                let adminRemoved = needsAdmin.filter { adminResult.cleanedPaths.contains($0.path) }
                let adminFailed = needsAdmin.filter { !adminResult.cleanedPaths.contains($0.path) }

                self.applyRemovedAppFiles(adminRemoved)
                for url in adminRemoved {
                    Logger.shared.log("Removed \(url.path) with administrator privileges", level: .info)
                }

                self.finishRemoval(
                    removedAny: !removed.isEmpty || !adminRemoved.isEmpty,
                    needsFullDiskAccess: needsFullDiskAccess,
                    attemptedAdmin: true,
                    failed: failed + adminFailed,
                    adminError: adminResult.errors.joined(separator: "; ")
                )
            }
        }
    }

    /// Move files to the Trash via FileManager.trashItem so the syscall
    /// originates from PureMac itself - TCC then registers PureMac in the
    /// Full Disk Access list. The previous AppleScript-via-Finder bridge
    /// caused the syscall to originate from Finder, which is why granting
    /// FDA to PureMac made no difference (issue #75).
    private func trashDirectly(urls: [URL], completion: @escaping ([URL], Bool, [URL], [URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
            var removed: [URL] = []
            var needsFullDiskAccess = false
            var needsAdmin: [URL] = []
            var failed: [URL] = []

            for url in urls {
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                    removed.append(url)
                } catch {
                    let nsError = error as NSError
                    if Self.isMissingFileError(nsError) {
                        Logger.shared.log("Trash skipped for \(url.path): file no longer exists", level: .info)
                        removed.append(url)
                    } else if Self.isPermissionDeniedError(nsError) {
                        if hasFullDiskAccess || Self.isLikelyAdministratorRemovalPath(url) {
                            needsAdmin.append(url)
                        } else {
                            needsFullDiskAccess = true
                            failed.append(url)
                        }
                    } else {
                        Logger.shared.log("Trash failed for \(url.path): \(error.localizedDescription)", level: .error)
                        failed.append(url)
                    }
                }
            }
            completion(removed, needsFullDiskAccess, needsAdmin, failed)
        }
    }

    private func applyRemovedAppFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Animate the row sweep-out (AppFilesView attaches the per-row
        // transitions). NSWorkspace is the Reduce Motion check available
        // outside a View's Environment.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            discoveredFiles.removeAll { urls.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                discoveredFiles.removeAll { urls.contains($0) }
            }
        }
        selectedFiles.subtract(urls)
        Logger.shared.log("Removed \(urls.count) file\(urls.count == 1 ? "" : "s")", level: .info)
    }

    private func finishRemoval(
        removedAny: Bool,
        needsFullDiskAccess: Bool,
        attemptedAdmin: Bool,
        failed: [URL],
        adminError: String?
    ) {
        // Freeze the failed batch before the FDA sheet opens so the retry
        // path can't be poisoned by later selection edits or app switches.
        lastFailedRemovalURLs = needsFullDiskAccess ? failed : []
        removalNeedsFullDiskAccess = needsFullDiskAccess
        if let message = removalFailureMessage(
            needsFullDiskAccess: needsFullDiskAccess,
            attemptedAdmin: attemptedAdmin,
            failed: failed,
            adminError: adminError
        ) {
            removalError = message
            Logger.shared.log(message, level: .error)
        }
        if removedAny {
            pruneMissingInstalledApps()
        }
    }

    /// Public bridge so views (e.g. AppFilesView) can build CleanableItem rows
    /// from raw URLs when retrying via the PermissionCoordinator.
    func makeUninstallCleanableItem(for url: URL) -> CleanableItem {
        cleanableUninstallItem(for: url)
    }

    private func cleanableUninstallItem(for url: URL) -> CleanableItem {
        let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ])
        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        return CleanableItem(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            category: .systemJunk,
            isSelected: true,
            lastModified: values?.contentModificationDate
        )
    }

    private func removalFailureMessage(
        needsFullDiskAccess: Bool,
        attemptedAdmin: Bool,
        failed: [URL],
        adminError: String?
    ) -> String? {
        if needsFullDiskAccess {
            guard !failed.isEmpty else { return String(localized: "Full Disk Access required") }
            return String(
                format: String(localized: "%lld item(s) need Full Disk Access to remove. Tap Grant Access to fix in one step."),
                Int64(failed.count)
            )
        }

        if !failed.isEmpty {
            let preview = failed.prefix(2).map { $0.lastPathComponent }.joined(separator: ", ")
            let extra = failed.count > 2
                ? String(format: String(localized: " and %lld more"), Int64(failed.count - 2))
                : ""
            return String(
                format: String(localized: "Couldn't remove %@%@. They may be in use or protected by macOS."),
                preview,
                extra
            )
        }

        if let adminError, !adminError.isEmpty {
            Logger.shared.log("Administrator removal failed: \(adminError)", level: .error)
            return String(localized: "Some files could not be removed")
        }
        return nil
    }

    private nonisolated static func isMissingFileError(_ nsError: NSError) -> Bool {
        (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
    }

    private nonisolated static func isPermissionDeniedError(_ nsError: NSError) -> Bool {
        (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError)) ||
            (nsError.domain == NSPOSIXErrorDomain &&
                (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
    }

    private nonisolated static func isLikelyAdministratorRemovalPath(_ url: URL) -> Bool {
        let path = (url.resolvingSymlinksInPath().path as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return hasAppBundleComponent(path, rootedAt: "/Applications")
            || hasAppBundleComponent(path, rootedAt: "\(home)/Applications")
            || isDirectFile(path, in: "/private/var/db/receipts", extensions: ["plist", "bom"])
            || isDirectFile(path, in: "/var/db/receipts", extensions: ["plist", "bom"])
            || isDirectFile(path, in: "/Library/LaunchDaemons", extensions: ["plist"])
            || isDirectFile(path, in: "/Library/LaunchAgents", extensions: ["plist"])
    }

    private nonisolated static func hasAppBundleComponent(_ path: String, rootedAt root: String) -> Bool {
        let normalizedRoot = (root as NSString).standardizingPath
        guard path != normalizedRoot else { return false }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard path.hasPrefix(rootWithSeparator) else { return false }
        let relative = String(path.dropFirst(rootWithSeparator.count))
        return relative.split(separator: "/").contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    private nonisolated static func isDirectFile(_ path: String, in root: String, extensions: Set<String>) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard parent == (root as NSString).standardizingPath else { return false }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }

    private func pruneMissingInstalledApps() {
        let fileManager = FileManager.default
        installedApps.removeAll { !fileManager.fileExists(atPath: $0.path.path) }

        if let selectedApp, !fileManager.fileExists(atPath: selectedApp.path.path) {
            self.selectedApp = nil
            discoveredFiles = []
            selectedFiles = []
        }
    }

    func findOrphans() {
        isSearchingOrphans = true
        orphanedFiles = []
        Task.detached(priority: .userInitiated) {
            let locations = Locations()
            let knownApps = await MainActor.run { self.installedApps }
            let knownIDs = Set(knownApps.map { $0.bundleIdentifier.normalizedForMatching() })
            let knownNames = Set(knownApps.map { $0.appName.normalizedForMatching() })
            // Paths the user marked "Always Ignore" (issue #114). These were
            // false positives for them, so they stay hidden from every scan
            // until the user forgets the list in Settings.
            let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])

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
                        if ignored.contains(fullPath.path) { continue }
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

    // MARK: - Orphan ignore list (#114)

    static let ignoredOrphansKey = "settings.orphans.ignored"

    /// Number of paths currently on the "always ignore" list. Read from
    /// UserDefaults each access so the Settings row tracks live changes.
    var ignoredOrphanCount: Int {
        UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey)?.count ?? 0
    }

    /// Permanently hide the given orphans from future scans and sweep them out
    /// of the current results.
    func ignoreOrphans(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])
        for url in urls { ignored.insert(url.path) }
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredOrphansKey)

        let urlSet = Set(urls)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orphanedFiles.removeAll { urlSet.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                orphanedFiles.removeAll { urlSet.contains($0) }
            }
        }
        Logger.shared.log("Ignoring \(urls.count) orphan(s) in future scans", level: .info)
    }

    /// Forget every ignored path so they can surface again on the next scan.
    func clearIgnoredOrphans() {
        UserDefaults.standard.removeObject(forKey: Self.ignoredOrphansKey)
        objectWillChange.send()
    }

    // MARK: - Selection

    func isItemSelected(_ item: CleanableItem) -> Bool {
        if item.isSelected {
            return !deselectedItems.contains(item.id)
        }
        return selectedCleanupItems.contains(item.id)
    }

    func toggleItem(_ item: CleanableItem) {
        if isItemSelected(item) {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
        } else {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func selectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
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

    private func clearSelectionState() {
        selectedCleanupItems.removeAll()
        deselectedItems.removeAll()
    }

    private func clearSelectionState(for category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            selectedCleanupItems.remove(item.id)
            deselectedItems.remove(item.id)
        }
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

    /// Request Full Disk Access via the rich PermissionCoordinator sheet and
    /// retry the supplied items once the user grants permission. Used by both
    /// the cleanup and app-uninstall flows so they share a single UI surface.
    ///
    /// The retry callback captures `items` directly rather than reading
    /// `pendingPermissionRetryItems` at fire time — that field is mutable
    /// app-wide and a second permission request would clobber it before the
    /// first callback resolves, sending the wrong items to retryCleanItems.
    func requestFullDiskAccessAndRetry(items: [CleanableItem], context: PermissionCoordinator.PromptContext) {
        pendingPermissionRetryItems = items
        let capturedItems = items
        PermissionCoordinator.shared.requestAccess(
            context: context,
            failedPaths: items.map { $0.path }
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingPermissionRetryItems = []
                self.cleanError = nil
                self.cleanErrorIsFDAFixable = false
                guard !capturedItems.isEmpty else { return }
                await self.retryCleanItems(capturedItems)
            }
        }
    }

    private func retryCleanItems(_ items: [CleanableItem]) async {
        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        var result = await cleaningEngine.cleanItems(items) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.cleanProgress = progress
                self?.scanState = .cleaning(progress: progress)
            }
        }
        if !result.requiresAdmin.isEmpty {
            let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
            result.cleanedPaths.formUnion(admin.cleanedPaths)
            result.itemsCleaned += admin.itemsCleaned
            result.freedSpace += admin.freedSpace
            result.errors.append(contentsOf: admin.errors)
            result.protectedPaths.formUnion(admin.protectedPaths)
        }

        totalFreedSpace = result.freedSpace
        lastCleanedDate = Date()

        for (cat, catResult) in categoryResults {
            let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
            let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
            for item in cleared {
                selectedCleanupItems.remove(item.id)
                deselectedItems.remove(item.id)
            }
            if remaining.isEmpty {
                categoryResults.removeValue(forKey: cat)
            } else {
                categoryResults[cat] = CategoryResult(
                    category: cat,
                    items: remaining,
                    totalSize: remaining.reduce(0) { $0 + $1.size }
                )
            }
        }
        totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

        // Route survivors back through the same outcome path the original
        // cleanup uses. Without this, an FDA revocation between grant and
        // retry would silently drop errors instead of re-popping the sheet.
        let survivors = survivingItems(from: items, result: result)
        handleCleanOutcome(errors: result.errors, survivors: survivors)

        scanState = .cleaned
        loadDiskInfo()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        scanState = .idle
        totalFreedSpace = 0
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
        clearSelectionState()

        Task {
            let categories = CleaningCategory.scannable
            let total = categories.count

            for (index, category) in categories.enumerated() {
                let progress = Double(index) / Double(total)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)

                let result = await scanEngine.scanCategory(category) { [weak self] path in
                    Task { @MainActor [weak self] in
                        self?.scanTicker.path = path
                    }
                }
                categoryResults[category] = result
                totalJunkSize += result.totalSize
            }

            scanProgress = 1.0
            scanTicker.path = ""
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
            clearSelectionState(for: category)
            let result = await scanEngine.scanCategory(category) { [weak self] path in
                Task { @MainActor [weak self] in
                    self?.scanTicker.path = path
                }
            }
            categoryResults[category] = result

            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            scanProgress = 1.0
            scanTicker.path = ""
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
            var result = await cleaningEngine.cleanItems(itemsToClean) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            // Escalate root-owned items via "with administrator privileges".
            // One auth prompt covers the entire batch.
            if !result.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
                result.cleanedPaths.formUnion(admin.cleanedPaths)
                result.itemsCleaned += admin.itemsCleaned
                result.freedSpace += admin.freedSpace
                result.errors.append(contentsOf: admin.errors)
                result.protectedPaths.formUnion(admin.protectedPaths)
            }

            totalFreedSpace = result.freedSpace
            lastCleanedDate = Date()
            if result.itemsCleaned > 0 { Haptics.successWithSound() }

            let survivors = survivingItems(from: itemsToClean, result: result)

            for (cat, catResult) in categoryResults {
                let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
                let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
                for item in cleared {
                    selectedCleanupItems.remove(item.id)
                    deselectedItems.remove(item.id)
                }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: cat)
                } else {
                    categoryResults[cat] = CategoryResult(
                        category: cat,
                        items: remaining,
                        totalSize: remaining.reduce(0) { $0 + $1.size }
                    )
                }
            }
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

            handleCleanOutcome(errors: result.errors, survivors: survivors)

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
            var cleanResult = await cleaningEngine.cleanItems(selectedItems) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            if !cleanResult.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: cleanResult.requiresAdmin)
                cleanResult.cleanedPaths.formUnion(admin.cleanedPaths)
                cleanResult.itemsCleaned += admin.itemsCleaned
                cleanResult.freedSpace += admin.freedSpace
                cleanResult.errors.append(contentsOf: admin.errors)
                cleanResult.protectedPaths.formUnion(admin.protectedPaths)
            }

            totalFreedSpace = cleanResult.freedSpace
            lastCleanedDate = Date()

            if let existing = categoryResults[category] {
                let remaining = existing.items.filter { !cleanResult.cleanedPaths.contains($0.path) }
                let cleared = existing.items.filter { cleanResult.cleanedPaths.contains($0.path) }
                for item in cleared {
                    selectedCleanupItems.remove(item.id)
                    deselectedItems.remove(item.id)
                }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: category)
                } else {
                    categoryResults[category] = CategoryResult(
                        category: category,
                        items: remaining,
                        totalSize: remaining.reduce(0) { $0 + $1.size }
                    )
                }
            }
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

            let survivors = survivingItems(from: selectedItems, result: cleanResult)
            handleCleanOutcome(errors: cleanResult.errors, survivors: survivors)

            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    /// Items that neither got cleaned nor were skipped as SIP-protected.
    /// Protected paths can't be removed even as root, so treating them as
    /// failures only produces a "Couldn't clean everything" alert the user
    /// can do nothing about (e.g. /private/var/log/wifi.log) — log and move on.
    private func survivingItems(from items: [CleanableItem], result: CleaningEngine.CleaningResult) -> [CleanableItem] {
        if result.skippedProtected > 0 {
            let protectedList = result.protectedPaths.sorted().joined(separator: ", ")
            Logger.shared.log("Skipped \(result.skippedProtected) macOS-protected item(s): \(protectedList)", level: .info)
        }
        return items.filter {
            !result.cleanedPaths.contains($0.path) && !result.protectedPaths.contains($0.path)
        }
    }

    /// Inspect a clean batch's leftovers and either route the user into the
    /// PermissionSheet (FDA is the most likely cause) or surface a richer
    /// error alert that lists actual paths instead of "Check the log".
    private func handleCleanOutcome(errors: [String], survivors: [CleanableItem]) {
        guard !errors.isEmpty || !survivors.isEmpty else {
            cleanError = nil
            cleanErrorIsFDAFixable = false
            pendingPermissionRetryItems = []
            return
        }

        let fdaGranted = FullDiskAccessManager.shared.hasFullDiskAccess
        // App-modifying survivors (thinning, localization stripping) fail on
        // root-owned bundles that Full Disk Access cannot make writable, so
        // they must not steer the user into a Grant Access loop that can
        // never succeed. Only junk-file survivors count toward that hint.
        let fdaFixableSurvivors = survivors.filter { !CleaningCategory.appModifying.contains($0.category) }
        let likelyFDA = !fdaGranted && !fdaFixableSurvivors.isEmpty
        cleanErrorIsFDAFixable = likelyFDA
        pendingPermissionRetryItems = survivors

        if likelyFDA {
            cleanError = String(
                format: String(localized: "%lld item(s) need Full Disk Access to remove. Tap Grant Access to fix in one step."),
                Int64(fdaFixableSurvivors.count)
            )
        } else if !survivors.isEmpty {
            let preview = survivors.prefix(2).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            let extra = survivors.count > 2 ? String(format: String(localized: " and %lld more"), Int64(survivors.count - 2)) : ""
            cleanError = String(
                format: String(localized: "Couldn't remove %@%@. They may be in use or protected by macOS."),
                preview, extra
            )
        } else if let first = errors.first {
            Logger.shared.log(first, level: .error)
            cleanError = String(localized: "Some files could not be removed")
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
        // App-modifying categories (see CleaningCategory.appModifying) never
        // run unattended — a scheduled autoClean must not re-sign or strip
        // installed apps behind the user's back.
        let categories = scheduler.config.categoriesToScan
            .filter { !CleaningCategory.appModifying.contains($0) }
        var totalFound: Int64 = 0
        clearSelectionState()
        categoryResults = [:]

        for category in categories {
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result
            totalFound += result.totalSize
        }

        totalJunkSize = totalFound

        if scheduler.config.autoClean && totalFound >= scheduler.config.minimumCleanSize {
            cleanAll()
        }

        // Purgeable space is intentionally NOT auto-purged: macOS reserves and
        // reclaims it on its own and PureMac does not claim to free it. See
        // CleaningCategory.scannable.

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

    private static func defaultAppFileScanner(
        app: InstalledApp,
        locations: Locations,
        completion: @escaping (Set<URL>) -> Void
    ) {
        let appInfo = AppPathFinder.AppInfo(
            appName: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            path: app.path,
            entitlements: nil,
            teamIdentifier: nil
        )
        let finder = AppPathFinder(appInfo: appInfo, locations: locations)
        finder.findPathsAsync(completion: completion)
    }
}
