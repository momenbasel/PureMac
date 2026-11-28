import Foundation

enum CleanupSizeFilter: String, CaseIterable, Identifiable {
    case any = "Any size"
    case megabytes100 = "Over 100 MB"
    case gigabyte1 = "Over 1 GB"
    case gigabytes10 = "Over 10 GB"

    var id: String { rawValue }

    var minimumBytes: Int64 {
        switch self {
        case .any: return 0
        case .megabytes100: return 100_000_000
        case .gigabyte1: return 1_000_000_000
        case .gigabytes10: return 10_000_000_000
        }
    }
}

enum CleanupAgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Older than 30 days"
    case sixMonths = "Older than 6 months"
    case year = "Older than a year"

    var id: String { rawValue }

    func cutoff(relativeTo now: Date) -> Date? {
        switch self {
        case .any: return nil
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .sixMonths: return Calendar.current.date(byAdding: .month, value: -6, to: now)
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        }
    }
}

enum CleanupSortOrder: String, CaseIterable, Identifiable {
    case largest = "Largest first"
    case smallest = "Smallest first"
    case oldest = "Oldest first"
    case name = "Name"

    var id: String { rawValue }
}

struct CleanupReviewFilter: Equatable {
    var query = ""
    var size: CleanupSizeFilter = .any
    var age: CleanupAgeFilter = .any
    var order: CleanupSortOrder = .largest

    func apply(to items: [CleanableItem], now: Date = Date()) -> [CleanableItem] {
        sorted(matching(items, now: now))
    }

    func matching(_ items: [CleanableItem], now: Date = Date(), isCancelled: () -> Bool = { false }) -> [CleanableItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = age.cutoff(relativeTo: now)
        if search.isEmpty && size == .any && cutoff == nil { return items }
        var matches: [CleanableItem] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256) && isCancelled() { return [] }
            guard item.size >= size.minimumBytes else { continue }
            if let cutoff {
                guard let modified = item.lastModified, modified < cutoff else { continue }
            }
            if search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                || item.path.localizedCaseInsensitiveContains(search) {
                matches.append(item)
            }
        }
        return matches
    }

    func sorted(_ items: [CleanableItem]) -> [CleanableItem] {
        items.sorted { left, right in
            switch order {
            case .largest where left.size != right.size: return left.size > right.size
            case .smallest where left.size != right.size: return left.size < right.size
            case .oldest where left.lastModified != right.lastModified:
                return (left.lastModified ?? .distantFuture) < (right.lastModified ?? .distantFuture)
            default:
                let comparison = left.name.localizedStandardCompare(right.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.path < right.path
            }
        }
    }
}

struct CleanupRowSelection {
    let selected: Set<UUID>
    let deselected: Set<UUID>
    let unavailable: Set<UUID>

    func isAvailable(_ item: CleanableItem) -> Bool {
        !unavailable.contains(item.id)
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        isAvailable(item) && (item.isSelected ? !deselected.contains(item.id) : selected.contains(item.id))
    }
}

enum CleanupFileIdentity: Equatable, Sendable {
    case virtual
    case missing
    case unreadable
    case file(device: dev_t, inode: ino_t, type: mode_t, size: off_t, seconds: Int, nanoseconds: Int, birthSeconds: Int, birthNanoseconds: Int)

    static func read(_ item: CleanableItem) -> Self {
        if item.isActionItem { return .virtual }
        return read(path: item.path)
    }

    var adminKey: String? {
        guard case let .file(device, inode, _, size, modified, _, birth, _) = self else { return nil }
        return "\(device):\(inode):\(size):\(modified):\(birth)"
    }

    static func read(path: String) -> Self {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        return Self(metadata: info)
    }

    fileprivate init(metadata info: stat) {
        self = .file(device: info.st_dev, inode: info.st_ino, type: info.st_mode & S_IFMT,
                     size: info.st_size, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec,
                     birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec)
    }
}

struct TrackedTrashMove: Sendable {
    enum Failure: LocalizedError {
        case occupied, destinationChanged, sourceChanged, unavailable, workspaceBusy, unverified

        var errorDescription: String? {
            switch self {
            case .occupied: return String(localized: "The original location is occupied.")
            case .destinationChanged: return String(localized: "The original folder is missing or changed.")
            case .sourceChanged: return String(localized: "The item in Trash is missing or changed.")
            case .unavailable: return String(localized: "Could not put the item back.")
            case .workspaceBusy: return String(localized: "Could not lock the workspace for restoration.")
            case .unverified: return String(localized: "Could not verify the restored item. Check its original location in Finder.")
            }
        }
    }

    private struct ParentIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int

        init?(_ descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_ino != 0, info.st_birthtimespec.tv_sec > 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    let originalURL: URL
    let trashURL: URL
    private let originalParent: ParentIdentity
    private let trashParent: ParentIdentity
    private let itemIdentity: CleanupFileIdentity

    static func moveToTrash(_ url: URL) throws -> (trashURL: URL?, recovery: Self?) {
        try capture(from: url) { source in
            var destination: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
            return destination as URL?
        }
    }

    static func capture(from original: URL, move: (URL) throws -> URL?) throws -> (trashURL: URL?, recovery: Self?) {
        let before = inspect(original)
        let destination = try move(original)
        guard let before, let destination, destination.standardizedFileURL != original.standardizedFileURL,
              let after = inspect(destination), after.item == before.item,
              CleanupFileIdentity.read(path: original.path) == .missing else { return (destination, nil) }
        return (destination, Self(originalURL: original, trashURL: destination, originalParent: before.parent,
                                  trashParent: after.parent, itemIdentity: after.item))
    }

    var verifiedTrashURL: URL? {
        guard let current = Self.inspect(trashURL), current.parent == trashParent, current.item == itemIdentity else { return nil }
        return trashURL
    }

    func putBack() throws {
        let destinationFD = Self.openParent(of: originalURL)
        guard destinationFD >= 0 else { throw Failure.destinationChanged }
        defer { close(destinationFD) }
        guard ParentIdentity(destinationFD) == originalParent else { throw Failure.destinationChanged }
        let sourceFD = Self.openParent(of: trashURL)
        guard sourceFD >= 0 else { throw Failure.sourceChanged }
        defer { close(sourceFD) }
        guard ParentIdentity(sourceFD) == trashParent,
              Self.identity(in: sourceFD, name: trashURL.lastPathComponent) == itemIdentity else {
            throw Failure.sourceChanged
        }
        guard renameatx_np(sourceFD, trashURL.lastPathComponent, destinationFD, originalURL.lastPathComponent,
                           UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
            switch errno {
            case EEXIST, ENOTEMPTY: throw Failure.occupied
            case ELOOP:
                var occupied = stat()
                if fstatat(destinationFD, originalURL.lastPathComponent, &occupied, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw Failure.occupied
                }
                throw Failure.sourceChanged
            case ENOENT: throw Failure.sourceChanged
            default: throw Failure.unavailable
            }
        }
        guard let restored = Self.inspect(originalURL), restored.parent == originalParent,
              restored.item == itemIdentity else {
            throw Failure.unverified
        }
    }

    private static func inspect(_ url: URL) -> (parent: ParentIdentity, item: CleanupFileIdentity)? {
        let descriptor = openParent(of: url)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let parent = ParentIdentity(descriptor),
              let item = identity(in: descriptor, name: url.lastPathComponent) else { return nil }
        return (parent, item)
    }

    private static func identity(in descriptor: Int32, name: String) -> CleanupFileIdentity? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_ino != 0, info.st_birthtimespec.tv_sec > 0,
              [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { return nil }
        return CleanupFileIdentity(metadata: info)
    }

    private static func openParent(of url: URL) -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else { return -1 }
        var path = url.deletingLastPathComponent().path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    }
}

struct CleanupSelection: Identifiable {
    let id = UUID()
    let items: [CleanableItem]

    init(items: [CleanableItem]) {
        self.items = items.map { item in
            var reviewed = item
            reviewed.reviewedIdentity = CleanupFileIdentity.read(item)
            return reviewed
        }
    }
}

enum CleanupOperation: CaseIterable, Hashable {
    case trash, delete, docker, cargo, simulator, managedCache, managedAction

    init(_ item: CleanableItem, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if item.simctlRuntimeIdentifier != nil { self = .simulator }
        else if item.category == .dockerCache && item.path.isEmpty { self = .docker }
        else if item.category == .rustTargets { self = .cargo }
        else if item.category == .devToolCaches,
                let root = DevToolCaches.root(forPath: item.path, home: homeDirectory.path),
                [.goCleanCache, .goCleanModcache, .uvCacheClean].contains(root.removal) { self = .managedCache }
        else if item.isActionItem || CleaningCategory.appModifying.contains(item.category) { self = .managedAction }
        else if XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(item.path, homeDirectory: homeDirectory) { self = .trash }
        else { self = .delete }
    }

    var title: String {
        switch self {
        case .delete: return String(localized: "Permanent · Delete files")
        case .trash: return String(localized: "Move to Trash")
        case .docker: return String(format: String(localized: "Permanent · %@"), "docker system prune -f")
        case .cargo: return String(format: String(localized: "Permanent · %@"), "cargo clean")
        case .simulator: return String(localized: "Permanent · Remove simulator runtime")
        case .managedCache: return String(localized: "Permanent · Clean tool cache")
        case .managedAction: return String(localized: "Permanent · Run cleanup action")
        }
    }
}

enum CleanupDisposition: String {
    case removed, trashed, restored, completed, missing, skipped, protected, failed

    var title: String {
        switch self {
        case .removed: return String(localized: "Removed")
        case .trashed: return String(localized: "Moved to Trash")
        case .restored: return String(localized: "Restored")
        case .completed: return String(localized: "Action completed")
        case .missing: return String(localized: "Already gone")
        case .skipped: return String(localized: "Skipped")
        case .protected: return String(localized: "Protected by macOS")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct CleanupReceipt {
    let id = UUID()

    struct Row: Identifiable {
        let item: CleanableItem
        var disposition: CleanupDisposition
        var bytes: Int64 = 0
        var detail: String?
        var trashPath: String?
        var requiresRescan = false
        var recovery: TrackedTrashMove?
        var recoveryUnavailable = false
        var id: UUID { item.id }
    }

    var rows: [Row]
    var removedBytes: Int64 {
        rows.filter { $0.disposition == .removed || $0.disposition == .completed }.reduce(0) { $0 + $1.bytes }
    }
    var trashedBytes: Int64 {
        rows.filter { $0.disposition == .trashed || $0.disposition == .restored }.reduce(0) { $0 + $1.bytes }
    }
    var attentionCount: Int {
        rows.filter { [.failed, .protected, .skipped].contains($0.disposition) }.count
    }
}

enum AppRemovalSource: Equatable, Sendable {
    case app(String)
    case leftovers
}

enum AppRemovalOutcome: String, Sendable {
    case ready = "Move to Trash"
    case trashed = "Moved to Trash"
    case restored = "Put back"
    case restoreUnverified = "Restore unverified"
    case needsAdmin = "Kept · Requires administrator"
    case needsAccess = "Kept · Requires Full Disk Access"
    case changed = "Kept · Item changed"
    case blocked = "Kept · Protected or excluded"
    case missing = "Already missing"
    case failed = "Could not remove"
    case deleted = "Permanently deleted"
}

struct AppRemovalFile: Identifiable, Sendable {
    let url: URL
    let identity: CleanupFileIdentity
    var outcome: AppRemovalOutcome
    var trashDestination: URL?
    var recovery: TrackedTrashMove?
    var recoveryError: String?
    var id: URL { url }

    init(_ url: URL) {
        self.url = url
        identity = CleanupFileIdentity.read(path: url.path)
        switch identity {
        case .missing: outcome = .missing
        case .file(_, _, let type, _, _, _, _, _): outcome = type == S_IFLNK ? .blocked : .ready
        case .unreadable, .virtual: outcome = .failed
        }
    }

    func disposition(source: AppRemovalSource, exclusions: [String]) -> AppRemovalOutcome {
        let current = Self(url)
        guard current.outcome == .ready else { return current.outcome }
        guard current.identity == identity else { return .changed }
        let path = url.resolvingSymlinksInPath().path
        guard !ProviderPaths.isProviderOwned(path),
              !highRiskHomeDotPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              !CleanupExclusions.excludes(path, paths: exclusions) else { return .blocked }
        if source == .leftovers && !OrphanSafetyPolicy.isSafeCandidate(url) { return .blocked }
        return .ready
    }
}

struct AppRemovalReview: Identifiable, Sendable {
    enum Stage { case trash, permanent, receipt }
    let id = UUID()
    let source: AppRemovalSource
    var files: [AppRemovalFile] {
        didSet { contentGeneration = UUID() }
    }
    private(set) var contentGeneration = UUID()
    var stage = Stage.trash

    var visibleFiles: [AppRemovalFile] {
        stage == .permanent ? files.filter { $0.outcome == .needsAdmin } : files
    }
}
