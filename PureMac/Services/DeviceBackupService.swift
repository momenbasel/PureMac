import CryptoKit
import Darwin
import Foundation

struct DeviceBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let allocatedSize: Int64
    let modifiedAt: Date
    fileprivate let fingerprint: String
    fileprivate let ancestors: [UInt64]

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DeviceBackupScanResult: Sendable {
    let backups: [DeviceBackup]
    let issues: [String]
}

struct DeviceBackupRemovalResult: Sendable {
    let removedPaths: [String]
    let errors: [String]
}

actor DeviceBackupService {
    private struct Measurement {
        var hasher = SHA256()
        var allocatedSize: Int64 = 0
        var count = 0
        var seenFiles: Set<String> = []
        var rootIdentity = ""
    }

    private let root: URL
    private let trashHandler: (URL) throws -> Void
    private let exclusions: () -> [String]
    private let maxEntries: Int

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashHandler: ((URL) throws -> Void)? = nil,
        exclusions: @escaping () -> [String] = { CleanupExclusions.paths() },
        maxEntries: Int = 500_000
    ) {
        root = homeDirectory.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
        self.trashHandler = trashHandler ?? { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        }
        self.exclusions = exclusions
        self.maxEntries = max(1, min(maxEntries, 500_000))
    }

    func scan() throws -> DeviceBackupScanResult {
        try Task.checkCancellation()
        let opened: (descriptor: Int32, identities: [UInt64])
        do {
            opened = try openRoot()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as POSIXError where error.code == .ENOENT {
            return DeviceBackupScanResult(backups: [], issues: [])
        } catch {
            return DeviceBackupScanResult(backups: [], issues: [error.localizedDescription])
        }
        defer { close(opened.descriptor) }
        var backups: [DeviceBackup] = []
        var issues: [String] = []
        for name in try names(in: opened.descriptor) {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(name, isDirectory: true)
            do {
                let info = try metadata(name, in: opened.descriptor)
                guard info.st_mode & S_IFMT != S_IFLNK else { throw failure("Symbolic links are excluded", url) }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                guard !CleanupExclusions.excludes(url.path, paths: exclusions()) else {
                    throw failure("Excluded from cleanup", url)
                }
                let measure = try measureBackup(name, in: opened.descriptor)
                backups.append(DeviceBackup(
                    url: url,
                    allocatedSize: measure.allocatedSize,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                    fingerprint: measure.hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                    ancestors: opened.identities
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append("\(name): \(error.localizedDescription)")
            }
        }
        return DeviceBackupScanResult(
            backups: backups.sorted { $0.allocatedSize > $1.allocatedSize },
            issues: issues
        )
    }

    func trash(_ backups: [DeviceBackup]) throws -> DeviceBackupRemovalResult {
        var removed: [String] = []
        var errors: [String] = []
        var seen: Set<URL> = []
        for backup in backups where seen.insert(backup.url).inserted {
            do {
                try Task.checkCancellation()
                guard backup.url.deletingLastPathComponent().path == root.path,
                      backup.url.standardizedFileURL.path == backup.url.path,
                      !backup.url.path.utf8.contains(0),
                      backup.url.path != root.path else {
                    throw failure("Only individual device backup folders can be moved to Trash", backup.url)
                }
                guard !CleanupExclusions.excludes(backup.url.path, paths: exclusions()) else {
                    throw failure("Excluded from cleanup", backup.url)
                }
                let opened = try openRoot()
                defer { close(opened.descriptor) }
                guard opened.identities == backup.ancestors else {
                    throw failure("The backup location changed. Scan again", backup.url)
                }
                let measure = try measureBackup(backup.name, in: opened.descriptor)
                let fingerprint = measure.hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard fingerprint == backup.fingerprint else {
                    throw failure("The backup changed. Scan again after the backup finishes", backup.url)
                }
                let finalRoot = try openRoot()
                defer { close(finalRoot.descriptor) }
                try validateCompletedBackup(backup.name, in: finalRoot.descriptor)
                guard finalRoot.identities == backup.ancestors,
                      try identity(metadata(backup.name, in: finalRoot.descriptor)) == measure.rootIdentity,
                      !CleanupExclusions.excludes(backup.url.path, paths: exclusions()) else {
                    throw failure("The backup location or exclusions changed. Scan again", backup.url)
                }
                try trashHandler(backup.url)
                removed.append(backup.url.path)
            } catch is CancellationError {
                errors.append(String(localized: "Backup removal was cancelled. Remaining backups were left in place."))
                break
            } catch {
                errors.append("\(backup.name): \(error.localizedDescription)")
            }
        }
        return DeviceBackupRemovalResult(removedPaths: removed, errors: errors)
    }

    private func openRoot() throws -> (descriptor: Int32, identities: [UInt64]) {
        guard root.path.hasPrefix("/"), root.path == root.standardizedFileURL.path,
              !root.path.utf8.contains(0) else { throw failure("Invalid backup location", root) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        var identities: [UInt64] = []
        do {
            for component in root.path.split(separator: "/") {
                try Task.checkCancellation()
                let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError() }
                close(descriptor)
                descriptor = next
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw posixError() }
                identities.append(UInt64(bitPattern: Int64(info.st_dev)))
                identities.append(UInt64(info.st_ino))
            }
            return (descriptor, identities)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func measureBackup(_ name: String, in descriptor: Int32) throws -> Measurement {
        try validateCompletedBackup(name, in: descriptor)
        var measurement = Measurement()
        try walk(name, relative: name, parent: descriptor, depth: 0, measurement: &measurement)
        try validateCompletedBackup(name, in: descriptor)
        return measurement
    }

    private func validateCompletedBackup(_ name: String, in descriptor: Int32) throws {
        let backup = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard backup >= 0 else { throw posixError() }
        defer { close(backup) }
        for marker in ["Manifest.plist", "Info.plist", "Status.plist", "Manifest.db"] {
            let info = try metadata(marker, in: backup)
            guard info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw failure("Only completed local device backups can be reviewed", root)
            }
        }
        let status = openat(backup, "Status.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard status >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: status, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["SnapshotState"] as? String == "finished" else {
            throw failure("This backup is incomplete or in progress. Use Finder to manage it", root)
        }
    }

    private func walk(_ name: String, relative: String, parent: Int32, depth: Int, measurement: inout Measurement) throws {
        try Task.checkCancellation()
        measurement.count += 1
        guard measurement.count <= maxEntries, depth < 128 else {
            throw failure("This backup exceeds the review limit; use Finder to manage it", root)
        }
        let before = try metadata(name, in: parent)
        if depth == 0 { measurement.rootIdentity = identity(before) }
        let kind = before.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG,
              depth != 0 || kind == S_IFDIR,
              before.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw failure("A backup contains a symbolic link, special file, or cloud-only item", root)
        }
        measurement.hasher.update(data: Data((relative + "\0" + identity(before) + "\0").utf8))
        let physicalID = "\(before.st_dev):\(before.st_ino)"
        if measurement.seenFiles.insert(physicalID).inserted {
            measurement.allocatedSize += max(0, Int64(before.st_blocks)) * 512
        }
        if kind == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixError() }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, identity(opened) == identity(before) else {
                throw failure("A backup changed while it was being read", root)
            }
            for childName in try names(in: child) {
                try walk(childName, relative: relative + "/" + childName, parent: child, depth: depth + 1, measurement: &measurement)
            }
        }
        guard try identity(metadata(name, in: parent)) == identity(before) else {
            throw failure("A backup changed while it was being read", root)
        }
    }

    private func names(in descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw posixError() }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw posixError()
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw failure("A backup contains an unreadable filename", root) }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= maxEntries else { throw failure("This folder exceeds the review limit", root) }
        }
        return result.sorted()
    }

    private func metadata(_ name: String, in descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        return info
    }

    private func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_blocks):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_flags)"
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func failure(_ message: String, _ url: URL) -> NSError {
        NSError(domain: "DeviceBackupService", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message): \(url.path)"])
    }
}
