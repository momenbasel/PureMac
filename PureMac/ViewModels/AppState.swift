import Darwin
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

/// An identity-bound source entry prepared for a later move to the user's
/// Trash. Keeping the lstat snapshot separate from the mutation lets a whole
/// uninstall batch be frozen before its first filesystem change.
struct SecureTrashCandidate: Sendable {
    let originalURL: URL
    let canonicalPath: String
    let identity: FileIdentity
}

enum SecureTrashMoveError: LocalizedError, Equatable {
    case invalidPath(String)
    case missing(String)
    case unsupportedType(String)
    case identityChanged(String)
    case unsafeTrash(String)
    case crossedDeviceBoundary(String)
    case recoveryFailed(String)
    case posix(operation: String, path: String, code: Int32)

    var isPermissionDenied: Bool {
        if case let .posix(_, _, code) = self {
            return code == EACCES || code == EPERM
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid Trash source path: \(path)"
        case let .missing(path):
            return "The item disappeared before it could be moved to Trash: \(path)"
        case let .unsupportedType(path):
            return "Unsupported filesystem object type: \(path)"
        case let .identityChanged(path):
            return "The item changed before it could be moved to Trash: \(path)"
        case let .unsafeTrash(path):
            return "The Trash directory is not safe to use: \(path)"
        case let .crossedDeviceBoundary(path):
            return "The item is on a different volume from the user's Trash: \(path)"
        case let .recoveryFailed(path):
            return "A raced item could not be restored safely after a Trash move: \(path)"
        case let .posix(operation, path, code):
            return "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Moves an exact lstat identity into ~/.Trash without asking Foundation to
/// resolve the source pathname again. Every parent component is opened with
/// O_NOFOLLOW, the leaf is held by a no-follow descriptor, and renameatx_np is
/// performed relative to the verified source/Trash directory descriptors.
struct SecureTrashMover: Sendable {
    private struct OpenTrash {
        let homeFD: Int32
        let trashFD: Int32
        let identity: FileIdentity
        let path: String
    }

    private let policy: SecureDeletionPolicy
    private let homeDirectory: String
    private let userID: uid_t
    private let beforeRevalidation: (@Sendable () throws -> Void)?
    private let afterRevalidationBeforeRename: (@Sendable () throws -> Void)?

    init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        userID: uid_t = getuid(),
        beforeRevalidation: (@Sendable () throws -> Void)? = nil,
        afterRevalidationBeforeRename: (@Sendable () throws -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.userID = userID
        policy = SecureDeletionPolicy(userID: userID, homeDirectory: homeDirectory)
        self.beforeRevalidation = beforeRevalidation
        self.afterRevalidationBeforeRename = afterRevalidationBeforeRename
    }

    func prepare(_ url: URL) throws -> SecureTrashCandidate {
        let path: String
        do {
            path = try policy.canonicalPath(url.path)
        } catch {
            throw SecureTrashMoveError.invalidPath(url.path)
        }

        let identity: FileIdentity
        switch FileIdentity.lookup(path: path) {
        case let .found(found):
            identity = found
        case .missing:
            throw SecureTrashMoveError.missing(path)
        case let .failed(code):
            throw SecureTrashMoveError.posix(operation: "lstat", path: path, code: code)
        }

        guard identity.isDirectory || identity.isRegularFile || identity.isSymbolicLink else {
            throw SecureTrashMoveError.unsupportedType(path)
        }
        return SecureTrashCandidate(
            originalURL: url,
            canonicalPath: path,
            identity: identity
        )
    }

    @discardableResult
    func moveToTrash(_ candidate: SecureTrashCandidate) throws -> URL {
        let source = try openSource(candidate)
        defer { Darwin.close(source.parentFD) }
        defer { Darwin.close(source.leafFD) }

        let trash = try openTrashDirectory()
        defer { Darwin.close(trash.trashFD) }
        defer { Darwin.close(trash.homeFD) }

        guard candidate.identity.device == trash.identity.device else {
            throw SecureTrashMoveError.crossedDeviceBoundary(candidate.canonicalPath)
        }
        guard !isAncestor(candidate.canonicalPath, of: trash.path) else {
            throw SecureTrashMoveError.unsafeTrash(trash.path)
        }

        try beforeRevalidation?()
        try verifySource(
            parentFD: source.parentFD,
            leafFD: source.leafFD,
            name: source.name,
            expected: candidate.identity,
            path: candidate.canonicalPath
        )
        try verifyTrashIsStillReachable(trash)

        // This hook exists solely for deterministic security tests. Shipping
        // callers leave it nil, so renameatx_np follows the final fstatat
        // revalidation immediately.
        try afterRevalidationBeforeRename?()

        let destinationName = try renameExclusivelyToTrash(
            sourceParentFD: source.parentFD,
            sourceName: source.name,
            sourcePath: candidate.canonicalPath,
            trashFD: trash.trashFD
        )

        do {
            let movedIdentity = try identityAt(
                parentFD: trash.trashFD,
                name: destinationName,
                path: candidate.canonicalPath
            )
            guard movedIdentity == candidate.identity else {
                try restoreUnexpectedMove(
                    trashFD: trash.trashFD,
                    trashName: destinationName,
                    movedIdentity: movedIdentity,
                    sourceParentFD: source.parentFD,
                    sourceName: source.name,
                    sourcePath: candidate.canonicalPath
                )
                throw SecureTrashMoveError.identityChanged(candidate.canonicalPath)
            }

            do {
                try verifyTrashIsStillReachable(trash)
            } catch {
                try restoreUnexpectedMove(
                    trashFD: trash.trashFD,
                    trashName: destinationName,
                    movedIdentity: movedIdentity,
                    sourceParentFD: source.parentFD,
                    sourceName: source.name,
                    sourcePath: candidate.canonicalPath
                )
                throw error
            }
        } catch let error as SecureTrashMoveError {
            throw error
        } catch {
            throw SecureTrashMoveError.recoveryFailed(candidate.canonicalPath)
        }

        return URL(fileURLWithPath: trash.path).appendingPathComponent(
            destinationName,
            isDirectory: candidate.identity.isDirectory
        )
    }

    private func openSource(
        _ candidate: SecureTrashCandidate
    ) throws -> (parentFD: Int32, leafFD: Int32, name: String) {
        let components = candidate.canonicalPath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw SecureTrashMoveError.invalidPath(candidate.canonicalPath)
        }

        let parentFD = try openDirectoryComponents(
            Array(components.dropLast()),
            displayPath: candidate.canonicalPath
        )
        do {
            var flags = O_EVTONLY | O_CLOEXEC
            if candidate.identity.isDirectory {
                flags |= O_DIRECTORY | O_NOFOLLOW
            } else if candidate.identity.isSymbolicLink {
                // O_SYMLINK opens the link vnode itself. Darwin rejects the
                // redundant O_NOFOLLOW combination with ELOOP.
                flags |= O_SYMLINK
            } else {
                flags |= O_NOFOLLOW
            }
            let leafFD = name.withCString { pointer in
                Darwin.openat(parentFD, pointer, flags)
            }
            guard leafFD >= 0 else {
                let code = errno
                if code == ENOENT {
                    throw SecureTrashMoveError.identityChanged(candidate.canonicalPath)
                }
                throw SecureTrashMoveError.posix(
                    operation: "openat",
                    path: candidate.canonicalPath,
                    code: code
                )
            }
            do {
                let descriptorIdentity = try identityOfDescriptor(
                    leafFD,
                    path: candidate.canonicalPath
                )
                guard descriptorIdentity == candidate.identity else {
                    throw SecureTrashMoveError.identityChanged(candidate.canonicalPath)
                }
                return (parentFD, leafFD, name)
            } catch {
                Darwin.close(leafFD)
                throw error
            }
        } catch {
            Darwin.close(parentFD)
            throw error
        }
    }

    private func openTrashDirectory() throws -> OpenTrash {
        let canonicalHome: String
        do {
            canonicalHome = try policy.canonicalPath(homeDirectory)
        } catch {
            throw SecureTrashMoveError.unsafeTrash(homeDirectory)
        }
        let homeComponents = canonicalHome.split(separator: "/").map(String.init)
        let homeFD = try openDirectoryComponents(homeComponents, displayPath: canonicalHome)

        do {
            let homeIdentity = try identityOfDescriptor(homeFD, path: canonicalHome)
            guard homeIdentity.isDirectory, homeIdentity.owner == UInt32(userID) else {
                throw SecureTrashMoveError.unsafeTrash(canonicalHome)
            }

            let trashName = ".Trash"
            var trashFD = trashName.withCString { pointer in
                Darwin.openat(
                    homeFD,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if trashFD < 0, errno == ENOENT {
                let createStatus = trashName.withCString { pointer in
                    Darwin.mkdirat(homeFD, pointer, mode_t(S_IRWXU))
                }
                if createStatus != 0, errno != EEXIST {
                    throw SecureTrashMoveError.posix(
                        operation: "mkdirat",
                        path: canonicalHome + "/.Trash",
                        code: errno
                    )
                }
                trashFD = trashName.withCString { pointer in
                    Darwin.openat(
                        homeFD,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard trashFD >= 0 else {
                throw SecureTrashMoveError.posix(
                    operation: "openat",
                    path: canonicalHome + "/.Trash",
                    code: errno
                )
            }

            do {
                var info = stat()
                guard Darwin.fstat(trashFD, &info) == 0 else {
                    throw SecureTrashMoveError.posix(
                        operation: "fstat",
                        path: canonicalHome + "/.Trash",
                        code: errno
                    )
                }
                let identity = FileIdentity(stat: info)
                let permissionBits = info.st_mode & mode_t(0o077)
                guard identity.isDirectory,
                      identity.owner == UInt32(userID),
                      permissionBits == 0
                else {
                    throw SecureTrashMoveError.unsafeTrash(canonicalHome + "/.Trash")
                }
                return OpenTrash(
                    homeFD: homeFD,
                    trashFD: trashFD,
                    identity: identity,
                    path: canonicalHome + "/.Trash"
                )
            } catch {
                Darwin.close(trashFD)
                throw error
            }
        } catch {
            Darwin.close(homeFD)
            throw error
        }
    }

    private func openDirectoryComponents(
        _ components: [String],
        displayPath: String
    ) throws -> Int32 {
        var currentFD = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentFD >= 0 else {
            throw SecureTrashMoveError.posix(operation: "open", path: "/", code: errno)
        }

        var traversed = ""
        do {
            for component in components {
                traversed += "/" + component
                let nextFD = component.withCString { pointer in
                    Darwin.openat(
                        currentFD,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextFD >= 0 else {
                    throw SecureTrashMoveError.posix(
                        operation: "openat",
                        path: traversed,
                        code: errno
                    )
                }
                Darwin.close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            Darwin.close(currentFD)
            throw error
        }
    }

    private func verifySource(
        parentFD: Int32,
        leafFD: Int32,
        name: String,
        expected: FileIdentity,
        path: String
    ) throws {
        guard try identityOfDescriptor(leafFD, path: path) == expected,
              try identityAt(parentFD: parentFD, name: name, path: path) == expected
        else {
            throw SecureTrashMoveError.identityChanged(path)
        }
    }

    private func verifyTrashIsStillReachable(_ trash: OpenTrash) throws {
        let visibleIdentity = try identityAt(
            parentFD: trash.homeFD,
            name: ".Trash",
            path: trash.path
        )
        guard visibleIdentity == trash.identity else {
            throw SecureTrashMoveError.unsafeTrash(trash.path)
        }
    }

    private func renameExclusivelyToTrash(
        sourceParentFD: Int32,
        sourceName: String,
        sourcePath: String,
        trashFD: Int32
    ) throws -> String {
        for attempt in 0..<8 {
            let destinationName = attempt == 0
                ? sourceName
                : collisionSafeName(for: sourceName)
            let status = sourceName.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        sourceParentFD,
                        sourcePointer,
                        trashFD,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if status == 0 { return destinationName }

            let code = errno
            if code == EEXIST { continue }
            if code == ENOENT {
                throw SecureTrashMoveError.identityChanged(sourcePath)
            }
            if code == EXDEV {
                throw SecureTrashMoveError.crossedDeviceBoundary(sourcePath)
            }
            throw SecureTrashMoveError.posix(
                operation: "renameatx_np",
                path: sourcePath,
                code: code
            )
        }
        throw SecureTrashMoveError.posix(
            operation: "renameatx_np",
            path: sourcePath,
            code: EEXIST
        )
    }

    private func restoreUnexpectedMove(
        trashFD: Int32,
        trashName: String,
        movedIdentity: FileIdentity,
        sourceParentFD: Int32,
        sourceName: String,
        sourcePath: String
    ) throws {
        guard try identityAt(
            parentFD: trashFD,
            name: trashName,
            path: sourcePath
        ) == movedIdentity else {
            throw SecureTrashMoveError.recoveryFailed(sourcePath)
        }

        let status = trashName.withCString { trashPointer in
            sourceName.withCString { sourcePointer in
                Darwin.renameatx_np(
                    trashFD,
                    trashPointer,
                    sourceParentFD,
                    sourcePointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0,
              try identityAt(
                  parentFD: sourceParentFD,
                  name: sourceName,
                  path: sourcePath
              ) == movedIdentity
        else {
            throw SecureTrashMoveError.recoveryFailed(sourcePath)
        }
    }

    private func identityAt(
        parentFD: Int32,
        name: String,
        path: String
    ) throws -> FileIdentity {
        var info = stat()
        let status = name.withCString { pointer in
            Darwin.fstatat(parentFD, pointer, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            let code = errno
            if code == ENOENT {
                throw SecureTrashMoveError.identityChanged(path)
            }
            throw SecureTrashMoveError.posix(
                operation: "fstatat",
                path: path,
                code: code
            )
        }
        return FileIdentity(stat: info)
    }

    private func identityOfDescriptor(_ descriptor: Int32, path: String) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw SecureTrashMoveError.posix(
                operation: "fstat",
                path: path,
                code: errno
            )
        }
        return FileIdentity(stat: info)
    }

    private func collisionSafeName(for originalName: String) -> String {
        let original = originalName as NSString
        let pathExtension = original.pathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : "." + pathExtension
        let suffix = " \(UUID().uuidString)" + extensionSuffix
        let stem = pathExtension.isEmpty
            ? originalName
            : original.deletingPathExtension
        let maximumStemBytes = max(1, Int(NAME_MAX) - suffix.utf8.count)
        var shortened = ""
        for character in stem {
            let candidate = shortened + String(character)
            guard candidate.utf8.count <= maximumStemBytes else { break }
            shortened = candidate
        }
        return shortened + suffix
    }

    private func isAncestor(_ possibleAncestor: String, of path: String) -> Bool {
        possibleAncestor == path || path.hasPrefix(possibleAncestor + "/")
    }
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
    /// True only when every surviving item has an explicit TCC/FDA denial
    /// from the user-level identity lookup. MainWindow uses this to route the
    /// user into PermissionSheet instead of the generic alert.
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
                removalError = "Refused to delete \(blocked.count) protected item(s) (home credential directory or similar)."
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await FilesystemMutationCoordinator.shared.acquire()
            } catch {
                self.removalError = error.localizedDescription
                Logger.shared.log(
                    "Uninstall blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                    level: .error
                )
                return
            }
            let directResult: DirectTrashResult
            do {
                try await self.cleaningEngine.ensurePrivilegedDeletionsAreSettled()
                directResult = await self.trashDirectly(urls: urls)
            } catch {
                await FilesystemMutationCoordinator.shared.release()
                self.removalError = error.localizedDescription
                Logger.shared.log(
                    "Uninstall blocked by unresolved privileged deletion: \(error.localizedDescription)",
                    level: .error
                )
                return
            }
            await FilesystemMutationCoordinator.shared.release()

            self.applyRemovedAppFiles(directResult.removed)

            guard !directResult.needsAdmin.isEmpty else {
                self.finishRemoval(
                    removedAny: !directResult.removed.isEmpty,
                    fullDiskAccessDenied: directResult.fullDiskAccessDenied,
                    ordinaryFailures: directResult.failures,
                    adminFailures: [],
                    adminError: nil
                )
                return
            }

            let items = directResult.needsAdmin.map {
                self.cleanableUninstallItem(
                    for: URL(fileURLWithPath: $0.canonicalPath),
                    fileIdentity: $0.identity
                )
            }
            let adminResult = await self.cleaningEngine.cleanWithAdminPrivileges(items: items)
            let adminRemoved = directResult.needsAdmin.filter {
                adminResult.cleanedPaths.contains($0.canonicalPath)
            }.map(\.originalURL)
            let adminFailed = directResult.needsAdmin.filter {
                !adminResult.cleanedPaths.contains($0.canonicalPath)
            }.map(\.originalURL)

            self.applyRemovedAppFiles(adminRemoved)
            for url in adminRemoved {
                Logger.shared.log("Removed \(url.path) with administrator privileges", level: .info)
            }

            self.finishRemoval(
                removedAny: !directResult.removed.isEmpty || !adminRemoved.isEmpty,
                fullDiskAccessDenied: directResult.fullDiskAccessDenied,
                ordinaryFailures: directResult.failures,
                adminFailures: adminFailed,
                adminError: adminResult.errors.joined(separator: "; ")
            )
        }
    }

    private struct DirectTrashResult: Sendable {
        let removed: [URL]
        let fullDiskAccessDenied: [URL]
        let needsAdmin: [SecureTrashCandidate]
        let failures: [URL]
    }

    /// Move exact lstat identities into ~/.Trash with descriptor-relative,
    /// no-follow renames. This keeps the normal recoverable Trash UX while
    /// ensuring neither Foundation nor Finder resolves a raced pathname.
    private func trashDirectly(urls: [URL]) async -> DirectTrashResult {
        let logger = Logger.shared
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
                let trashMover = SecureTrashMover()
                var removed: [URL] = []
                var fullDiskAccessDenied: [URL] = []
                var needsAdmin: [SecureTrashCandidate] = []
                var failed: [URL] = []
                var candidates: [SecureTrashCandidate] = []

                // Freeze every source identity before the first namespace
                // mutation in this batch. A temporary ENOENT is deliberately
                // retained as a failure, never promoted to "removed".
                for url in urls {
                    do {
                        candidates.append(try trashMover.prepare(url))
                    } catch {
                        let nsError = error as NSError
                        if Self.isPermissionDeniedError(nsError)
                            || (error as? SecureTrashMoveError)?.isPermissionDenied == true {
                            // No identity was captured, so root escalation is
                            // forbidden. FDA + a fresh user-confirmed retry is
                            // the only safe continuation.
                            fullDiskAccessDenied.append(url)
                        } else {
                            logger.log(
                                "Trash preparation failed for \(url.path): \(error.localizedDescription)",
                                level: .error
                            )
                            failed.append(url)
                        }
                    }
                }

                for candidate in candidates {
                    let url = candidate.originalURL
                    do {
                        _ = try trashMover.moveToTrash(candidate)
                        removed.append(url)
                    } catch {
                        let nsError = error as NSError
                        let permissionDenied = Self.isPermissionDeniedError(nsError)
                            || (error as? SecureTrashMoveError)?.isPermissionDenied == true
                        if permissionDenied {
                            if hasFullDiskAccess || Self.isLikelyAdministratorRemovalPath(url) {
                                needsAdmin.append(candidate)
                            } else {
                                fullDiskAccessDenied.append(url)
                            }
                        } else {
                            logger.log(
                                "Secure Trash move failed for \(url.path): \(error.localizedDescription)",
                                level: .error
                            )
                            failed.append(url)
                        }
                    }
                }
                continuation.resume(returning: DirectTrashResult(
                    removed: removed,
                    fullDiskAccessDenied: fullDiskAccessDenied,
                    needsAdmin: needsAdmin,
                    failures: failed
                ))
            }
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
        fullDiskAccessDenied: [URL],
        ordinaryFailures: [URL],
        adminFailures: [URL],
        adminError: String?
    ) {
        let normalizedAdminError = adminError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldOfferFullDiskAccess = !fullDiskAccessDenied.isEmpty
            && ordinaryFailures.isEmpty
            && adminFailures.isEmpty
            && (normalizedAdminError?.isEmpty ?? true)

        // Freeze the failed batch before the FDA sheet opens so the retry
        // path can't be poisoned by later selection edits or app switches.
        lastFailedRemovalURLs = shouldOfferFullDiskAccess ? fullDiskAccessDenied : []
        removalNeedsFullDiskAccess = shouldOfferFullDiskAccess
        if let message = removalFailureMessage(
            fullDiskAccessDenied: fullDiskAccessDenied,
            ordinaryFailures: ordinaryFailures,
            adminFailures: adminFailures,
            adminError: normalizedAdminError
        ) {
            removalError = message
            Logger.shared.log(message, level: .error)
        }
        if removedAny {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await FilesystemMutationCoordinator.shared.acquire()
                } catch {
                    Logger.shared.log(
                        "Installed-app pruning blocked because the filesystem mutation lease failed: \(error.localizedDescription)",
                        level: .warning
                    )
                    return
                }
                do {
                    try await self.cleaningEngine.ensurePrivilegedDeletionsAreSettled()
                    self.pruneMissingInstalledApps()
                    await FilesystemMutationCoordinator.shared.release()
                } catch {
                    await FilesystemMutationCoordinator.shared.release()
                    Logger.shared.log(
                        "Installed-app pruning deferred until privileged reconciliation: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }
        }
    }

    /// Public bridge so views (e.g. AppFilesView) can build CleanableItem rows
    /// from raw URLs when retrying via the PermissionCoordinator.
    func makeUninstallCleanableItem(for url: URL) -> CleanableItem {
        cleanableUninstallItem(for: url)
    }

    private func cleanableUninstallItem(
        for url: URL,
        fileIdentity: FileIdentity? = nil
    ) -> CleanableItem {
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
            lastModified: values?.contentModificationDate,
            fileIdentity: fileIdentity
        )
    }

    private func removalFailureMessage(
        fullDiskAccessDenied: [URL],
        ordinaryFailures: [URL],
        adminFailures: [URL],
        adminError: String?
    ) -> String? {
        var messages: [String] = []

        if let adminError, !adminError.isEmpty {
            messages.append("Administrator removal failed: \(adminError)")
        } else if !adminFailures.isEmpty {
            let noun = adminFailures.count == 1 ? "file" : "files"
            messages.append(
                "\(adminFailures.count) \(noun) could not be removed with administrator privileges. The items may have changed or macOS denied access."
            )
        }

        if !ordinaryFailures.isEmpty {
            let noun = ordinaryFailures.count == 1 ? "file" : "files"
            messages.append(
                "\(ordinaryFailures.count) \(noun) could not be removed. Check that the items still exist and are not in use."
            )
        }

        if !fullDiskAccessDenied.isEmpty {
            let noun = fullDiskAccessDenied.count == 1 ? "file" : "files"
            messages.append(
                "\(fullDiskAccessDenied.count) \(noun) could not be removed because PureMac does not have Full Disk Access. Grant Full Disk Access in System Settings, then try again."
            )
        }

        return messages.isEmpty ? nil : messages.joined(separator: " ")
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

    /// Removes orphan rows through the same identity-bound descriptor walker as
    /// the main cleaner. Permission failures are sent to the single-purpose XPC
    /// helper; no orphan path is ever interpolated into a root shell command.
    func removeOrphansSecurely(
        _ urls: [URL]
    ) async -> (removed: Set<URL>, failedPaths: [String], failureDetails: [String]) {
        var failedPaths: [String] = []
        var failureDetails: [String] = []
        let candidates = urls.filter { url in
            guard OrphanSafetyPolicy.isSafeCandidate(url) else {
                failedPaths.append(url.path)
                failureDetails.append("\(url.path) (blocked by safety policy)")
                return false
            }
            return true
        }

        let items = candidates.map { url in
            CleanableItem(
                name: url.lastPathComponent,
                path: url.path,
                size: 0,
                category: .systemJunk,
                isSelected: true,
                lastModified: nil
            )
        }

        var cleanResult = await cleaningEngine.cleanItems(items) { _ in }
        if !cleanResult.requiresAdmin.isEmpty {
            let admin = await cleaningEngine.cleanWithAdminPrivileges(items: cleanResult.requiresAdmin)
            cleanResult.cleanedPaths.formUnion(admin.cleanedPaths)
            cleanResult.fullDiskAccessPaths.formUnion(admin.fullDiskAccessPaths)
            cleanResult.errors.append(contentsOf: admin.errors)
        }

        let removed = Set(candidates.filter { cleanResult.cleanedPaths.contains($0.path) })
        failureDetails.append(contentsOf: cleanResult.errors)
        failedPaths.append(contentsOf: candidates
            .filter { !cleanResult.cleanedPaths.contains($0.path) }
            .map(\.path))
        return (removed, failedPaths, failureDetails)
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

    /// Request Full Disk Access via the rich PermissionCoordinator sheet. A
    /// retry is automatic only when every item already has a scan identity;
    /// paths that TCC prevented us from identifying must be rescanned and
    /// confirmed rather than silently bound to whatever appears after grant.
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
                guard capturedItems.allSatisfy({ $0.fileIdentity != nil }) else {
                    let message = "Full Disk Access is enabled. Scan again and confirm the items before deleting them; PureMac will not automatically reuse a path whose filesystem identity could not be verified."
                    switch context {
                    case .uninstall:
                        self.removalError = message
                    case .cleanup, .general:
                        self.cleanError = message
                    }
                    return
                }
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
            result.fullDiskAccessPaths.formUnion(admin.fullDiskAccessPaths)
            result.itemsCleaned += admin.itemsCleaned
            result.freedSpace += admin.freedSpace
            result.errors.append(contentsOf: admin.errors)
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
        let survivors = items.filter { !result.cleanedPaths.contains($0.path) }
        handleCleanOutcome(
            errors: result.errors,
            survivors: survivors,
            fullDiskAccessPaths: result.fullDiskAccessPaths
        )

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

            // Escalate root-owned items through the authenticated XPC helper.
            // One Authorization Services prompt covers the chunked batch.
            if !result.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
                result.cleanedPaths.formUnion(admin.cleanedPaths)
                result.fullDiskAccessPaths.formUnion(admin.fullDiskAccessPaths)
                result.itemsCleaned += admin.itemsCleaned
                result.freedSpace += admin.freedSpace
                result.errors.append(contentsOf: admin.errors)
            }

            totalFreedSpace = result.freedSpace
            lastCleanedDate = Date()
            if result.itemsCleaned > 0 { Haptics.successWithSound() }

            let survivors = itemsToClean.filter { !result.cleanedPaths.contains($0.path) }

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

            handleCleanOutcome(
                errors: result.errors,
                survivors: survivors,
                fullDiskAccessPaths: result.fullDiskAccessPaths
            )

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
                cleanResult.fullDiskAccessPaths.formUnion(admin.fullDiskAccessPaths)
                cleanResult.itemsCleaned += admin.itemsCleaned
                cleanResult.freedSpace += admin.freedSpace
                cleanResult.errors.append(contentsOf: admin.errors)
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

            let survivors = selectedItems.filter { !cleanResult.cleanedPaths.contains($0.path) }
            handleCleanOutcome(
                errors: cleanResult.errors,
                survivors: survivors,
                fullDiskAccessPaths: cleanResult.fullDiskAccessPaths
            )

            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    /// Inspect a clean batch's leftovers and either route the user into the
    /// PermissionSheet (FDA is the most likely cause) or surface a richer
    /// error alert that lists actual paths instead of "Check the log".
    private func handleCleanOutcome(
        errors: [String],
        survivors: [CleanableItem],
        fullDiskAccessPaths: Set<String>
    ) {
        guard !errors.isEmpty || !survivors.isEmpty else {
            cleanError = nil
            cleanErrorIsFDAFixable = false
            pendingPermissionRetryItems = []
            return
        }

        let fdaGranted = FullDiskAccessManager.shared.hasFullDiskAccess
        let fdaSurvivors = survivors.filter { fullDiskAccessPaths.contains($0.path) }
        let hasNonFDAFailure = survivors.contains { !fullDiskAccessPaths.contains($0.path) }
        let likelyFDA = !fdaGranted && !fdaSurvivors.isEmpty && !hasNonFDAFailure
        cleanErrorIsFDAFixable = likelyFDA
        pendingPermissionRetryItems = likelyFDA ? fdaSurvivors : []

        if likelyFDA {
            cleanError = String(
                format: String(localized: "%lld item(s) need Full Disk Access to inspect. Grant access, then rescan to confirm them safely."),
                Int64(fdaSurvivors.count)
            )
        } else if let first = errors.first {
            // Authorization cancellation, helper registration/transport
            // errors and policy rejections are actionable as reported. Never
            // replace them with an unrelated FDA or "in use" suggestion.
            cleanError = first
        } else if !survivors.isEmpty {
            let preview = survivors.prefix(2).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            let extra = survivors.count > 2 ? String(format: String(localized: " and %lld more"), Int64(survivors.count - 2)) : ""
            cleanError = String(
                format: String(localized: "Couldn't remove %@%@. They may be in use or protected by macOS."),
                preview, extra
            )
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
