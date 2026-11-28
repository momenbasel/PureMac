import SwiftUI
import Combine
import UserNotifications
import AppKit

// InstalledApp is defined in AppInfoFetcher.swift

enum AppSection: Hashable {
    case apps
    case orphans
    case spaceExplorer
    case duplicates
    case similarPhotos
    case protection
    case performance
    case appleFeatures
    case appUpdates
    case settings
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
    let languageAtLaunch = AppLanguage.current
    @Published var settingsNeedLanguageRestart = false
    @Published var showUpdateSettings = false
    @Published var deviceBackupRemovalInProgress = false
    @Published var deviceBackupRemovalResult: DeviceBackupRemovalResult?
    var canRemoveDeviceBackups: Bool {
        restoringCleanupItem == nil && !scanState.isActive && !deviceBackupRemovalInProgress && appRemovalReview == nil && !isRemovingAppFiles
    }
    var canBeginAppRemoval: Bool {
        appRemovalReview == nil && !isRemovingAppFiles && restoringCleanupItem == nil && !scanState.isActive && !showCleanConfirmation
            && !deviceBackupRemovalInProgress && !PermissionCoordinator.shared.isRequesting
    }

    typealias AppFileScanner = @MainActor (
        _ app: InstalledApp,
        _ locations: Locations,
        _ completion: @escaping (Set<URL>) -> Void
    ) -> Void
    typealias AppFileTrasher = @Sendable (URL) throws -> URL?

    // MARK: - Scan / Clean State

    @Published var selectedCategory: CleaningCategory = .smartScan
    @Published var scanState: ScanState = .idle
    @Published var categoryResults: [CleaningCategory: CategoryResult] = [:]
    @Published var diskInfo = DiskInfo()
    @Published var totalJunkSize: Int64 = 0
    @Published var totalFreedSpace: Int64 = 0
    @Published var scanProgress: Double = 0
    @Published var scanWasCancelled = false
    @Published var lastScanDate: Date?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var cleanupGeneration = UUID()
    @Published var cleanProgress: Double = 0
    @Published var currentScanCategory: String = ""
    /// Live filesystem path the scan engine is touching, feeding the dashboard's
    /// ticker. Deliberately NOT a `@Published` on AppState — it updates ~10×/sec
    /// and would otherwise invalidate the whole view tree (issues #119, #120).
    /// Only the ticker label observes this object directly.
    let scanTicker = ScanProgressTicker()
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date?
    @Published private(set) var lastCleanupReceipt: CleanupReceipt?
    @Published private(set) var restoringCleanupItem: UUID?
    @Published private(set) var lastCleanupCategory: CleaningCategory?
    @Published private(set) var isAuthorizingCleanup = false
    @Published private var invalidatedCleanupIDs: Set<UUID> = []
    @Published var selectedCleanupItems: Set<UUID> = []
    @Published var deselectedItems: Set<UUID> = []
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published var cleanError: String?
    @Published private(set) var lastCleanupHadFailures = false
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
    @Published var isRemovingAppFiles = false
    @Published private(set) var appRemovalReview: AppRemovalReview?
    @Published var appFileScanLocationCount: Int = 0
    /// Set when a right-clicked app arrives via the Finder Services handler.
    /// MainWindow consumes it on both onChange AND onAppear so a request that
    /// lands before MainWindow mounts (cold launch, or while onboarding is
    /// still showing) is still surfaced — a one-shot token would be missed.
    @Published var pendingExternalApp: InstalledApp?

    private var externalUninstallObserver: AnyCancellable?
    private var appFileScanGeneration = UUID()

    // MARK: - Services

    let scheduler: SchedulerService
    private var unattendedScanGeneration: UUID?
    private var scheduleActivationObserver: AnyCancellable?
    private let scanEngine: ScanEngine
    private let cleaningEngine: CleaningEngine
    let scanCategories: [CleaningCategory]
    let cleanupHomeDirectory: URL
    private let locationsProvider: () -> Locations
    private let appFileScanner: AppFileScanner
    private let appFileTrasher: AppFileTrasher?

    // MARK: - Computed

    var totalItemCount: Int {
        categoryResults.values.reduce(0) { $0 + $1.itemCount }
    }

    var currentCategoryResult: CategoryResult? {
        categoryResults[selectedCategory]
    }

    var allResults: [CategoryResult] {
        CleaningCategory.scannable.compactMap { categoryResults[$0] }.filter { !$0.items.isEmpty }
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
        scheduler: SchedulerService? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scanCategories: [CleaningCategory] = CleaningCategory.scannable,
        locationsProvider: @escaping () -> Locations = Locations.init,
        appFileScanner: @escaping AppFileScanner = AppState.defaultAppFileScanner,
        appFileTrasher: AppFileTrasher? = nil
    ) {
        self.scheduler = scheduler ?? SchedulerService()
        cleanupHomeDirectory = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeDirectory)
        self.scanEngine = ScanEngine(homeDirectory: cleanupHomeDirectory)
        self.cleaningEngine = CleaningEngine(homeDirectory: cleanupHomeDirectory)
        self.scanCategories = scanCategories.filter(CleaningCategory.scannable.contains)
        self.locationsProvider = locationsProvider
        self.appFileScanner = appFileScanner
        self.appFileTrasher = appFileTrasher

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
            self.scheduler.setTrigger { [weak self] in
                await self?.runScheduledScan() ?? .cancelled
            }
            scheduleActivationObserver = NotificationCenter.default
                .publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.unattendedScanGeneration = nil }
            self.scheduler.start()
        }
    }

    // MARK: - App Loading

    func loadInstalledApps() {
#if DEBUG
        if CleanupUITestFixture.home != nil { return }
#endif
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
        let generation = UUID()
        appFileScanGeneration = generation
        appFileScanner(app, locations) { [weak self] urls in
            guard let self, self.appFileScanGeneration == generation else { return }
            let sorted = urls.sorted { $0.path < $1.path }
            self.discoveredFiles = sorted
            let home = self.cleanupHomeDirectory.path
            let volatileRoots = ["\(home)/Library/Caches/", "\(home)/Library/Logs/", "/Library/Caches/", "/Library/Logs/"]
            self.selectedFiles = urls.filter { url in
                let path = url.standardizedFileURL.path
                return path == app.path.standardizedFileURL.path || volatileRoots.contains(where: path.hasPrefix)
            }
            self.isScanningAppFiles = false
            self.appFileScanLocationCount = 0
        }
    }

    func reviewSelectedAppFiles(_ urls: Set<URL>) {
        guard let app = selectedApp else { return }
        beginRemovalReview(urls.intersection(discoveredFiles), source: .app(app.appName))
    }

    func reviewSelectedLeftovers(_ urls: Set<URL>) {
        beginRemovalReview(urls.intersection(orphanedFiles), source: .leftovers)
    }

    private func beginRemovalReview(_ urls: Set<URL>, source: AppRemovalSource) {
        guard !urls.isEmpty, canBeginAppRemoval else { return }
        let exclusions = CleanupExclusions.paths()
        let files = urls.sorted { $0.path < $1.path }.map { url in
            var file = AppRemovalFile(url)
            if file.outcome == .ready {
                file.outcome = file.disposition(source: source, exclusions: exclusions)
            }
            return file
        }
        appRemovalReview = AppRemovalReview(source: source, files: files)
    }

    func closeAppRemovalReview() {
        guard !isRemovingAppFiles else { return }
        if appRemovalReview?.stage == .permanent {
            appRemovalReview?.stage = .receipt
        } else {
            appRemovalReview = nil
        }
    }

    func reviewProtectedAppFiles() {
        guard !isRemovingAppFiles, appRemovalReview?.stage == .receipt,
              appRemovalReview?.files.contains(where: { $0.outcome == .needsAdmin }) == true else { return }
        appRemovalReview?.stage = .permanent
    }

    func performAppRemovalReview() async {
        guard let review = appRemovalReview, !isRemovingAppFiles, restoringCleanupItem == nil, review.stage != .receipt,
              !scanState.isActive, !deviceBackupRemovalInProgress else { return }
        isRemovingAppFiles = true
        defer { isRemovingAppFiles = false }
        var updates: [URL: AppRemovalFile]
        if review.stage == .permanent {
            let outcomes = await cleaningEngine.removeReviewedAppFiles(review.visibleFiles, source: review.source)
            updates = Dictionary(uniqueKeysWithValues: review.visibleFiles.map { file in
                var updated = file
                updated.outcome = outcomes[file.url] ?? .failed
                return (file.url, updated)
            })
        } else {
            let trasher = appFileTrasher
            let targets = review.files.filter { $0.outcome == .ready }
            let hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
            let home = cleanupHomeDirectory
            updates = await Task.detached(priority: .userInitiated) {
                let exclusions = CleanupExclusions.paths()
                return Dictionary(uniqueKeysWithValues: targets.map { file in
                    let updated = Self.trashReviewedFile(file, source: review.source, exclusions: exclusions,
                                                         hasFullDiskAccess: hasFullDiskAccess, home: home, trasher: trasher)
                    return (file.url, updated)
                })
            }.value
        }

        for file in review.files where updates[file.url]?.outcome == .needsAdmin {
            if !(await cleaningEngine.isEligibleForReviewedDeletion(file, source: review.source)) {
                updates[file.url]?.outcome = .blocked
            }
        }
        var receipt = review
        receipt.files = review.files.map { updates[$0.url] ?? $0 }
        receipt.stage = .receipt
        appRemovalReview = receipt
        let gone = Set(updates.values.compactMap { file in
            [.trashed, .deleted, .missing].contains(file.outcome) ? file.url : nil
        })
        guard !gone.isEmpty else { return }
        switch review.source {
        case .app:
            discoveredFiles.removeAll { gone.contains($0) }
            selectedFiles.subtract(gone)
            pruneMissingInstalledApps()
        case .leftovers:
            orphanedFiles.removeAll { gone.contains($0) }
        }
    }

    private nonisolated static func trashReviewedFile(
        _ file: AppRemovalFile, source: AppRemovalSource, exclusions: [String],
        hasFullDiskAccess: Bool, home: URL, trasher: AppFileTrasher?
    ) -> AppRemovalFile {
        var updated = file
        updated.outcome = file.disposition(source: source, exclusions: exclusions)
        guard updated.outcome == .ready else { return updated }
        do {
            let move: (trashURL: URL?, recovery: TrackedTrashMove?)
            if let trasher {
                move = try TrackedTrashMove.capture(from: file.url, move: trasher)
            } else {
                move = try TrackedTrashMove.moveToTrash(file.url)
            }
            updated.outcome = .trashed
            updated.trashDestination = move.trashURL
            updated.recovery = move.recovery
        } catch {
            let error = error as NSError
            if isMissingFileError(error) {
                updated.outcome = .missing
            } else if !isPermissionDeniedError(error) {
                updated.outcome = .failed
            } else if FileProtection.isProtectedFromDeletion(path: file.url.path) {
                updated.outcome = .blocked
            } else if hasFullDiskAccess || isLikelyAdministratorRemovalPath(file.url, home: home.path)
                        || (source == .leftovers && file.url.path.hasPrefix("/Library/")) {
                updated.outcome = .needsAdmin
            } else {
                updated.outcome = .needsAccess
            }
        }
        return updated
    }

    func revealTrashedAppFile(reviewID: UUID, url: URL) async {
        guard let review = appRemovalReview, review.id == reviewID, review.stage == .receipt, !isRemovingAppFiles,
              let index = review.files.firstIndex(where: { $0.url == url && $0.outcome == .trashed }),
              let recovery = review.files[index].recovery else { return }
        let verifiedURL = await Task.detached(priority: .userInitiated) { recovery.verifiedTrashURL }.value
        guard appRemovalReview?.id == reviewID, appRemovalReview?.stage == .receipt, !isRemovingAppFiles,
              appRemovalReview?.files[index].outcome == .trashed else { return }
        guard let verifiedURL else {
            appRemovalReview?.files[index].recovery = nil
            appRemovalReview?.files[index].recoveryError = TrackedTrashMove.Failure.sourceChanged.localizedDescription
            return
        }
        appRemovalReview?.files[index].recoveryError = nil
        NSWorkspace.shared.activateFileViewerSelecting([verifiedURL])
    }

    func putBackAppFile(reviewID: UUID, url: URL) async {
        guard var review = appRemovalReview, review.id == reviewID, review.stage == .receipt,
              !isRemovingAppFiles, restoringCleanupItem == nil, !scanState.isActive, !deviceBackupRemovalInProgress,
              let index = review.files.firstIndex(where: { $0.url == url && $0.outcome == .trashed }),
              let recovery = review.files[index].recovery else { return }
        isRemovingAppFiles = true
        defer { isRemovingAppFiles = false }
        do {
            try await Task.detached(priority: .userInitiated) { try recovery.putBack() }.value
            review.files[index].outcome = .restored
            review.files[index].recovery = nil
            review.files[index].recoveryError = nil
            switch review.source {
            case .app:
                if url.pathExtension.lowercased() == "app" { loadInstalledApps() }
                if let selectedApp { scanForAppFiles(selectedApp) }
            case .leftovers:
                findOrphans()
            }
        } catch {
            switch error {
            case TrackedTrashMove.Failure.sourceChanged:
                review.files[index].recovery = nil
            case TrackedTrashMove.Failure.unverified:
                review.files[index].recovery = nil
                review.files[index].outcome = .restoreUnverified
            default:
                break
            }
            review.files[index].recoveryError = error.localizedDescription
        }
        appRemovalReview = review
    }

    func requestReviewedAppFileAccess() {
        guard let review = appRemovalReview, review.stage == .receipt, !isRemovingAppFiles,
              !PermissionCoordinator.shared.isRequesting else { return }
        let paths = review.files.filter { $0.outcome == .needsAccess }.map { $0.url.path }
        guard !paths.isEmpty else { return }
        let context: PermissionCoordinator.PromptContext
        switch review.source {
        case .app(let name): context = .uninstall(appName: name, failedCount: paths.count)
        case .leftovers: context = .cleanup(failedCount: paths.count)
        }
        appRemovalReview = nil
        PermissionCoordinator.shared.requestAccess(context: context, failedPaths: paths) { [weak self] in
            Task { @MainActor in await self?.retryReviewedAppFileAccess(review) }
        }
    }

    func retryReviewedAppFileAccess(_ receipt: AppRemovalReview) async {
        guard appRemovalReview == nil, !isRemovingAppFiles, receipt.stage == .receipt,
              receipt.files.contains(where: { $0.outcome == .needsAccess }) else { return }
        var retry = receipt
        for index in retry.files.indices where retry.files[index].outcome == .needsAccess {
            retry.files[index].outcome = .ready
        }
        retry.stage = .trash
        appRemovalReview = retry
        await performAppRemovalReview()
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

    private nonisolated static func isLikelyAdministratorRemovalPath(_ url: URL, home: String) -> Bool {
        let path = (url.resolvingSymlinksInPath().path as NSString).standardizingPath

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

    var excludedCleanupPaths: [String] {
        CleanupExclusions.paths()
    }

    func excludeFromCleanup(_ item: CleanableItem) {
        guard !item.isActionItem, !scanState.isActive else { return }
        CleanupExclusions.add(item.path)
        for (category, result) in categoryResults {
            categoryResults[category] = applyingCleanupExclusions(to: result)
        }
        totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
    }

    func removeCleanupExclusion(_ path: String) {
        UserDefaults.standard.set(excludedCleanupPaths.filter { $0 != path }, forKey: CleanupExclusions.defaultsKey)
        objectWillChange.send()
    }

    private func applyingCleanupExclusions(to result: CategoryResult) -> CategoryResult {
        let excluded = excludedCleanupPaths
        guard !excluded.isEmpty else { return result }
        let items = result.items.filter { !CleanupExclusions.excludes($0.path, paths: excluded) }
        return CategoryResult(category: result.category, items: items, totalSize: items.reduce(0) { $0 + $1.size })
    }

    func setSelection(_ selected: Bool, for items: [CleanableItem]) {
        guard !scanState.isActive else { return }
        updateBulkSelection(selected, items: items)
    }

    private func updateBulkSelection(_ selected: Bool, items: [CleanableItem], includeUnavailable: Bool = false) {
        var selectedOverrides = selectedCleanupItems
        var deselectedOverrides = deselectedItems
        let unavailable = invalidatedCleanupIDs
        for item in items {
            if !includeUnavailable && unavailable.contains(item.id) { continue }
            if selected && item.selectOnlyByHand { continue }
            if item.isSelected {
                if selected { deselectedOverrides.remove(item.id) }
                else { deselectedOverrides.insert(item.id) }
            } else {
                if selected { selectedOverrides.insert(item.id) }
                else { selectedOverrides.remove(item.id) }
            }
        }
        if selectedOverrides != selectedCleanupItems { selectedCleanupItems = selectedOverrides }
        if deselectedOverrides != deselectedItems { deselectedItems = deselectedOverrides }
    }

    // MARK: - Selection

    func isCleanupItemAvailable(_ item: CleanableItem) -> Bool {
        !invalidatedCleanupIDs.contains(item.id)
    }

    var cleanupRowSelection: CleanupRowSelection {
        CleanupRowSelection(selected: selectedCleanupItems, deselected: deselectedItems, unavailable: invalidatedCleanupIDs)
    }

    func isItemSelected(_ item: CleanableItem) -> Bool {
        cleanupRowSelection.isSelected(item)
    }

    func toggleItem(_ item: CleanableItem) {
        guard isCleanupItemAvailable(item) else { return }
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
        updateBulkSelection(true, items: result.items)
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        updateBulkSelection(false, items: result.items, includeUnavailable: true)
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
        invalidatedCleanupIDs.removeAll()
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
                await self.retryAfterFullDiskAccess(items: capturedItems, context: context)
            }
        }
    }

    func retryAfterFullDiskAccess(items: [CleanableItem], context: PermissionCoordinator.PromptContext) async {
        pendingPermissionRetryItems = []
        cleanError = nil
        cleanErrorIsFDAFixable = false
        guard !items.isEmpty else { return }
        if case .uninstall = context { return }
        await retryCleanItems(items)
    }

    private func retryCleanItems(_ items: [CleanableItem]) async {
        await startCleanup(items, category: lastCleanupCategory)?.value
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
        guard restoringCleanupItem == nil, !scanState.isActive, !deviceBackupRemovalInProgress else { return }
        beginScan(categories: scanCategories, replacingResults: true)
    }

    func scanSingleCategory(_ category: CleaningCategory) {
        guard restoringCleanupItem == nil, !scanState.isActive, !deviceBackupRemovalInProgress,
              scanCategories.contains(category) else { return }
        beginScan(categories: [category], replacingResults: false)
    }

    func cancelScan() {
        guard case .scanning = scanState else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration = UUID()
        scanWasCancelled = true
        scanTicker.path = ""
        scanState = .completed
    }

    private func beginScan(categories: [CleaningCategory], replacingResults: Bool) {
        let generation = UUID()
        scanGeneration = generation
        scanWasCancelled = false
        lastCleanupCategory = nil
        totalFreedSpace = 0
        scanProgress = 0
        scanState = .scanning(progress: 0, currentCategory: "Preparing...")
        if replacingResults {
            categoryResults = [:]
            totalJunkSize = 0
            clearSelectionState()
        }
        scanTask = Task {
            for (index, category) in categories.enumerated() {
                guard !Task.isCancelled, scanGeneration == generation else { return }
                let progress = Double(index) / Double(categories.count)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)
                clearSelectionState(for: category)
                let result = await scanEngine.scanCategory(category) { [weak self] path in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.scanTicker.path = path
                    }
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                if let previous = categoryResults[category] {
                    invalidatedCleanupIDs.subtract(previous.items.map(\.id))
                }
                categoryResults[category] = applyingCleanupExclusions(to: result)
                totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            }
            scanProgress = 1
            scanTicker.path = ""
            lastScanDate = Date()
            scanState = .completed
            scanTask = nil
            loadDiskInfo()
        }
    }

    // MARK: - Cleaning

    @discardableResult
    func cleanAll(itemIDs: Set<UUID>? = nil, scheduled: Bool = false) -> Task<Void, Never>? {
        let candidates = scheduled ? scheduledCleanupCandidates : allResults.flatMap(\.items).filter(isItemSelected)
        let itemsToClean = candidates.filter { itemIDs?.contains($0.id) ?? true }
        if scheduled && itemsToClean.reduce(0, { $0 + $1.size }) < scheduler.config.minimumCleanSize {
            return nil
        }
        return startCleanup(itemsToClean, category: nil)
    }

    func cleanCategory(_ category: CleaningCategory, itemIDs: Set<UUID>? = nil) {
        let selected = categoryResults[category]?.items.filter {
            isItemSelected($0) && (itemIDs?.contains($0.id) ?? true)
        } ?? []
        startCleanup(selected, category: category)
    }

    @discardableResult
    func putBackCleanupItem(_ id: UUID, receiptID: UUID) -> Task<Void, Never>? {
        guard restoringCleanupItem == nil, !scanState.isActive, !deviceBackupRemovalInProgress, !showCleanConfirmation,
              !isRemovingAppFiles, appRemovalReview == nil,
              let receipt = lastCleanupReceipt, receipt.id == receiptID,
              let row = receipt.rows.first(where: { $0.id == id }),
              row.disposition == .trashed, !row.recoveryUnavailable, let recovery = row.recovery else { return nil }
        restoringCleanupItem = id
        return Task {
            defer { restoringCleanupItem = nil }
            let failure: Error?
            do {
                try await cleaningEngine.putBack(recovery)
                failure = nil
            } catch {
                failure = error
            }
            guard var current = lastCleanupReceipt, current.id == receipt.id,
                  let index = current.rows.firstIndex(where: { $0.id == id }) else { return }
            if let failure {
                current.rows[index].detail = failure.localizedDescription
                if let reason = failure as? TrackedTrashMove.Failure, reason == .sourceChanged || reason == .unverified {
                    current.rows[index].recoveryUnavailable = true
                }
            } else {
                current.rows[index].disposition = .restored
                current.rows[index].detail = nil
                current.rows[index].recovery = nil
                loadDiskInfo()
            }
            lastCleanupReceipt = current
        }
    }

    @discardableResult
    func cleanReviewed(_ selection: CleanupSelection, category: CleaningCategory? = nil) -> Task<Void, Never>? {
        let currentIDs = Set(allResults.flatMap(\.items).filter(isItemSelected).map(\.id))
        let approved = selection.items.filter { currentIDs.contains($0.id) }
        let skipped: [CleanupReceipt.Row] = selection.items.filter { isCleanupItemAvailable($0) && !currentIDs.contains($0.id) }.map {
            .init(item: $0, disposition: .skipped, detail: String(localized: "Selection changed. Review this item again."))
        }
        return startCleanup(approved, category: category, skipped: skipped)
    }

    @discardableResult
    private func startCleanup(_ items: [CleanableItem], category: CleaningCategory?,
                              skipped: [CleanupReceipt.Row] = []) -> Task<Void, Never>? {
        let eligible = items.filter(isCleanupItemAvailable)
        guard restoringCleanupItem == nil, !scanState.isActive, !deviceBackupRemovalInProgress,
              appRemovalReview == nil, !isRemovingAppFiles,
              !eligible.isEmpty || !skipped.isEmpty else { return nil }
        let generation = UUID()
        cleanupGeneration = generation
        lastCleanupCategory = nil
        cleanProgress = 0
        scanState = .cleaning(progress: 0)
        return Task {
            var result = await cleaningEngine.cleanItems(eligible) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.cleanupGeneration == generation, case .cleaning = self.scanState else { return }
                    self.cleanProgress = progress
                    self.scanState = .cleaning(progress: progress)
                }
            }
            if !result.requiresAdmin.isEmpty {
                isAuthorizingCleanup = true
                let elevated = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
                result.merge(elevated)
                isAuthorizingCleanup = false
            }
            result.receiptRows.append(contentsOf: skipped)
            let receipt = CleanupReceipt(rows: result.receiptRows)
            lastCleanupReceipt = receipt
            lastCleanupCategory = category
            totalFreedSpace = receipt.removedBytes
            if result.itemsCleaned > 0 {
                lastCleanedDate = Date()
                Haptics.successWithSound()
            }

            let changedPaths = Set(receipt.rows.filter(\.requiresRescan).map(\.item.path))
            if !changedPaths.isEmpty {
                let changed = allResults.flatMap(\.items).filter { changedPaths.contains($0.path) }.map(\.id)
                invalidatedCleanupIDs.formUnion(changed)
                selectedCleanupItems.subtract(changed)
                deselectedItems.formUnion(changed)
            }
            let completedIDs = Set(receipt.rows.filter {
                [.removed, .trashed, .completed, .missing].contains($0.disposition)
            }.map(\.id))
            selectedCleanupItems.subtract(completedIDs)
            deselectedItems.subtract(completedIDs)
            for (key, existing) in categoryResults {
                let remaining = existing.items.filter { !completedIDs.contains($0.id) }
                if remaining.count == existing.items.count { continue }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: key)
                } else {
                    categoryResults[key] = CategoryResult(category: key, items: remaining,
                                                          totalSize: remaining.reduce(0) { $0 + $1.size })
                }
            }
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            let denied = receipt.rows.filter {
                $0.disposition == .failed && result.permissionDenied.contains($0.id)
            }.map(\.item)
            handleCleanOutcome(errors: result.errors, survivors: denied)
            lastCleanupHadFailures = receipt.attentionCount > 0
            scanState = category != nil && !allResults.isEmpty && !lastCleanupHadFailures ? .completed : .cleaned
            loadDiskInfo()
        }
    }

    /// Inspect a clean batch's leftovers and either route the user into the
    /// PermissionSheet (FDA is the most likely cause) or surface a richer
    /// error alert that lists actual paths instead of "Check the log".
    private func handleCleanOutcome(errors: [String], survivors: [CleanableItem]) {
        lastCleanupHadFailures = !errors.isEmpty || !survivors.isEmpty
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
            cleanError = first
        }
    }

    // MARK: - Purgeable

    func purgePurgeable() {
        loadDiskInfo()
    }

    // MARK: - Scheduled Scan

    var scheduledCleanupCandidates: [CleanableItem] {
        allResults.flatMap(\.items).filter { item in
            guard item.category != .trashBins, item.isSelected, !item.selectOnlyByHand, isItemSelected(item) else {
                return false
            }
            if XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(item.path, homeDirectory: cleanupHomeDirectory) {
                return XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(item, homeDirectory: cleanupHomeDirectory)
            }
            return true
        }
    }

    func canRunScheduledScan(isAppActive: Bool) -> Bool {
        guard restoringCleanupItem == nil, !scanState.isActive, !showCleanConfirmation, !isScanningAppFiles, !isRemovingAppFiles, appRemovalReview == nil,
              !isSearchingOrphans, !deviceBackupRemovalInProgress, !PermissionCoordinator.shared.isRequesting else {
            return false
        }
        if scanState == .completed || scanState == .cleaned {
            return !isAppActive && unattendedScanGeneration == scanGeneration
                && selectedCleanupItems.isEmpty && deselectedItems.isEmpty
        }
        return true
    }

    func runScheduledScan() async -> ScheduledScanOutcome {
        guard canRunScheduledScan(isAppActive: NSApp.isActive) else { return .deferred }
        let categories = scheduler.config.categoriesToScan.filter(scanCategories.contains)
        guard !categories.isEmpty else { return .cancelled }
        let autoClean = scheduler.config.autoClean
        let deadline = scheduler.config.nextRunDate
        let generation = UUID()
        scanGeneration = generation
        unattendedScanGeneration = NSApp.isActive ? nil : generation
        scanWasCancelled = false
        clearSelectionState()
        categoryResults = [:]
        totalJunkSize = 0
        for (index, category) in categories.enumerated() {
            let progress = Double(index) / Double(categories.count)
            scanState = .scanning(progress: progress, currentCategory: category.rawValue)
            scanProgress = progress
            currentScanCategory = category.rawValue
            let result = applyingCleanupExclusions(to: await scanEngine.scanCategory(category))
            guard scanGeneration == generation, !Task.isCancelled else { return .cancelled }
            categoryResults[category] = result
            totalJunkSize += result.totalSize
        }
        scanProgress = 1
        lastScanDate = Date()
        scanState = .completed
        let found = ByteCountFormatter.string(fromByteCount: totalJunkSize, countStyle: .file)
        var notification = String(format: String(localized: "Scheduled scan found %@."), found)
        if autoClean && scheduler.config.autoClean && scheduler.config.isEnabled && deadline == scheduler.config.nextRunDate,
           let cleanup = cleanAll(scheduled: true) {
            await cleanup.value
            if lastCleanupHadFailures {
                unattendedScanGeneration = nil
                notification = String(localized: "Scheduled cleanup needs attention. Review the results in PureMac.")
            } else {
                notification = String(localized: "Scheduled cleanup finished. Review the results in PureMac.")
            }
        }
        if scheduler.config.notifyOnCompletion && scheduler.config.isEnabled {
            sendNotification(message: notification)
        }
        return .completed
    }

    private func sendNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "PureMac"
        content.body = message
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
