import Darwin
import Foundation

enum AppleStorageKind: String, Sendable {
    case intelligenceModels
    case screenSavers
    case garageBand
    case appleLoops
    case deviceBackups

    var title: String {
        switch self {
        case .intelligenceModels: return String(localized: "Apple Intelligence models")
        case .screenSavers: return String(localized: "Downloaded screen savers")
        case .garageBand: return String(localized: "GarageBand support files")
        case .appleLoops: return String(localized: "Apple Loops")
        case .deviceBackups: return String(localized: "iPhone and iPad backups")
        }
    }

    var detail: String {
        switch self {
        case .intelligenceModels:
            return String(localized: "The known generative-model folder. macOS manages these assets; this size is not a promise of space you can recover.")
        case .screenSavers:
            return String(localized: "Downloaded Apple aerial assets. Change the selected wallpaper or screen saver in System Settings.")
        case .garageBand:
            return String(localized: "Sound libraries and support files may be shared with music apps. Review Music Creation in Storage settings.")
        case .appleLoops:
            return String(localized: "Loops used by GarageBand and Logic Pro. Review Music Creation in Storage settings before removing sounds.")
        case .deviceBackups:
            return String(localized: "Local device backups can contain your only restore copy. Review individual backups below or use Finder's Manage Backups.")
        }
    }
}

struct AppleStorageLocation: Sendable {
    let kind: AppleStorageKind
    let url: URL
}

struct AppleStorageItem: Identifiable, Sendable {
    enum Status: String, Sendable {
        case complete
        case partial
        case unavailable
        case notPresent
    }

    let kind: AppleStorageKind
    let url: URL
    let allocatedBytes: Int64?
    let status: Status
    let scannedCount: Int
    let skippedCount: Int
    let inaccessibleCount: Int
    let reachedLimit: Bool

    var id: URL { url }
    var title: String { kind.title }
    var detail: String { kind.detail }
    var path: String { url.path }
}

enum AppleStorageService {
    static func standardLocations(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AppleStorageLocation] {
        [
            AppleStorageLocation(kind: .intelligenceModels, url: URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels")),
            AppleStorageLocation(kind: .screenSavers, url: URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd")),
            AppleStorageLocation(kind: .garageBand, url: URL(fileURLWithPath: "/Library/Application Support/GarageBand")),
            AppleStorageLocation(kind: .appleLoops, url: URL(fileURLWithPath: "/Library/Audio/Apple Loops")),
            AppleStorageLocation(kind: .deviceBackups, url: homeDirectory.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true))
        ]
    }

    static func scan(
        locations: [AppleStorageLocation] = standardLocations(),
        maxEntriesPerLocation: Int = 100_000
    ) async throws -> [AppleStorageItem] {
        let task = Task.detached(priority: .utility) {
            try locations.map { location in
                try Task.checkCancellation()
                return try measure(location, limit: max(1, min(maxEntriesPerLocation, 100_000)))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    private static func measure(_ location: AppleStorageLocation, limit: Int) throws -> AppleStorageItem {
        let root = location.url.standardizedFileURL
        var bytes: Int64 = 0
        var count = 0
        var skipped = 0
        var inaccessible = 0
        var reachedLimit = false
        var seen: Set<Identity> = []

        func result(_ status: AppleStorageItem.Status, bytes: Int64?) -> AppleStorageItem {
            AppleStorageItem(kind: location.kind, url: root, allocatedBytes: bytes, status: status,
                             scannedCount: count, skippedCount: skipped, inaccessibleCount: inaccessible,
                             reachedLimit: reachedLimit)
        }

        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            try Task.checkCancellation()
            ancestor.appendPathComponent(component)
            var metadata = stat()
            guard lstat(ancestor.path, &metadata) == 0 else {
                if errno == ENOENT { return result(.notPresent, bytes: nil) }
                inaccessible += 1
                return result(.unavailable, bytes: nil)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
                skipped += 1
                return result(.unavailable, bytes: nil)
            }
        }

        guard let rootValues = try? root.resourceValues(forKeys: resourceKeys),
              rootValues.isPackage != true, !isCloudOnly(rootValues),
              FileManager.default.isReadableFile(atPath: root.path) else {
            inaccessible += 1
            return result(.unavailable, bytes: nil)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in
                inaccessible += 1
                return true
            }
        ) else {
            inaccessible += 1
            return result(.unavailable, bytes: nil)
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard count < limit else {
                reachedLimit = true
                break
            }
            count += 1
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                inaccessible += 1
                enumerator.skipDescendants()
                continue
            }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR,
                  metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
                skipped += 1
                enumerator.skipDescendants()
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                inaccessible += 1
                enumerator.skipDescendants()
                continue
            }
            let isModelPackage = location.kind == .intelligenceModels
                && ["mlmodelc", "mpsgraphpackage", "bundle"].contains(url.pathExtension.lowercased())
            guard values.isPackage != true || isModelPackage, !isCloudOnly(values) else {
                skipped += 1
                enumerator.skipDescendants()
                continue
            }
            if seen.insert(Identity(device: metadata.st_dev, inode: metadata.st_ino)).inserted {
                bytes += max(0, Int64(metadata.st_blocks)) * 512
            }
        }

        try Task.checkCancellation()
        if count == 0 && inaccessible > 0 { return result(.unavailable, bytes: nil) }
        let status: AppleStorageItem.Status = skipped > 0 || inaccessible > 0 || reachedLimit ? .partial : .complete
        return result(status, bytes: bytes)
    }

    private static func isCloudOnly(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded
    }
}
