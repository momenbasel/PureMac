import CryptoKit
import Darwin
import Foundation

struct DuplicateFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let flags: UInt32

    var physicalID: DuplicatePhysicalFileID {
        DuplicatePhysicalFileID(device: device, inode: inode)
    }
}

struct DuplicatePhysicalFileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modifiedAt: Date?
    let digest: String
    let identity: DuplicateFileIdentity

    var id: URL { url }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let digest: String
    let files: [DuplicateFile]

    var id: String { digest }
    var keeper: DuplicateFile { files[0] }
    var fileSize: Int64 { files[0].size }
    var reclaimableSize: Int64 { fileSize * Int64(max(0, files.count - 1)) }

    func contains(_ url: URL) -> Bool {
        files.contains { $0.url == url }
    }
}

enum DuplicateSkipReason: String, Hashable, Sendable {
    case symbolicLink
    case package
    case cloudPlaceholder
    case hardLink
    case inaccessible
    case changedDuringScan
    case unreadable

    var label: String {
        switch self {
        case .symbolicLink: return String(localized: "Symbolic link")
        case .package: return String(localized: "Package contents")
        case .cloudPlaceholder: return String(localized: "Cloud-only file")
        case .hardLink: return String(localized: "Hard-linked copy")
        case .inaccessible: return String(localized: "Access denied")
        case .changedDuringScan: return String(localized: "Changed during scan")
        case .unreadable: return String(localized: "Could not read")
        }
    }
}

struct DuplicateSkippedFile: Identifiable, Hashable, Sendable {
    let url: URL
    let reason: DuplicateSkipReason
    let detail: String?

    var id: String { "\(reason.rawValue):\(url.path)" }
}

struct DuplicateScanResult: Hashable, Sendable {
    let folder: URL
    let groups: [DuplicateGroup]
    let skippedFiles: [DuplicateSkippedFile]
    let filesInspected: Int
    let bytesHashed: Int64

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.files.count } }
    var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
}

struct DuplicateScanProgress: Hashable, Sendable {
    enum Phase: String, Hashable, Sendable {
        case discovering
        case hashing
    }

    let phase: Phase
    let filesInspected: Int
    let filesToHash: Int
    let filesHashed: Int
    let bytesHashed: Int64
    let currentURL: URL?

    var fractionCompleted: Double? {
        guard phase == .hashing, filesToHash > 0 else { return nil }
        return min(1, Double(filesHashed) / Double(filesToHash))
    }
}

struct DuplicateTrashFailure: Identifiable, Hashable, Sendable {
    let url: URL
    let message: String

    var id: URL { url }
}

struct DuplicateTrashReport: Hashable, Sendable {
    let trashedFiles: [DuplicateFile]
    let failures: [DuplicateTrashFailure]

    var bytesMovedToTrash: Int64 { trashedFiles.reduce(0) { $0 + $1.size } }
}

enum DuplicateFinderError: LocalizedError, Equatable {
    case invalidFolder(String)
    case invalidSelection(String)
    case keeperChanged(String)
    case fileChanged(String)
    case contentChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let path):
            return String(format: String(localized: "The selected folder cannot be scanned: %@"), path)
        case .invalidSelection(let path):
            return String(format: String(localized: "The protected copy cannot be moved to Trash: %@"), path)
        case .keeperChanged(let path):
            return String(format: String(localized: "The copy marked Keep is missing or changed: %@"), path)
        case .fileChanged(let path):
            return String(format: String(localized: "A selected file is missing or changed: %@"), path)
        case .contentChanged(let path):
            return String(format: String(localized: "A selected file no longer matches its kept copy: %@"), path)
        }
    }
}

actor DuplicateFinder {
    typealias ProgressHandler = @Sendable (DuplicateScanProgress) async -> Void
    typealias TrashHandler = (URL) throws -> Void
    typealias PreTrashHandler = (URL) throws -> Void

    private struct Candidate: Sendable {
        let url: URL
        let identity: DuplicateFileIdentity
        let modifiedAt: Date?
    }

    private struct DigestKey: Hashable {
        let size: Int64
        let digest: String
    }

    private let fileManager: FileManager
    private let trashHandler: TrashHandler
    private let preTrashHandler: PreTrashHandler?

    init(
        fileManager: FileManager = .default,
        trashHandler: TrashHandler? = nil,
        preTrashHandler: PreTrashHandler? = nil
    ) {
        self.fileManager = fileManager
        self.preTrashHandler = preTrashHandler
        self.trashHandler = trashHandler ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    func scan(
        folder rawFolder: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> DuplicateScanResult {
        let folder = rawFolder.standardizedFileURL
        guard Self.identity(at: folder) != nil, Self.isDirectory(at: folder) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }
        guard !Self.isSymbolicLink(at: folder), !Self.isPackage(at: folder), !Self.isCloudPlaceholder(at: folder) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }
        var candidatesBySize: [Int64: [Candidate]] = [:]
        var seenPhysicalFiles: [DuplicatePhysicalFileID: URL] = [:]
        var skipped: [DuplicateSkippedFile] = []
        var filesInspected = 0
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                skipped.append(DuplicateSkippedFile(
                    url: url.standardizedFileURL,
                    reason: .inaccessible,
                    detail: error.localizedDescription
                ))
                return true
            }
        ) else {
            throw DuplicateFinderError.invalidFolder(folder.path)
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let normalizedURL = url.standardizedFileURL
            if Self.isSymbolicLink(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .symbolicLink, detail: nil))
                continue
            }
            if Self.isPackage(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .package, detail: nil))
                continue
            }
            if Self.isCloudPlaceholder(at: normalizedURL) {
                enumerator.skipDescendants()
                skipped.append(DuplicateSkippedFile(url: normalizedURL, reason: .cloudPlaceholder, detail: nil))
                continue
            }
            guard let identity = Self.identity(at: normalizedURL), Self.isRegularFile(at: normalizedURL) else {
                continue
            }

            filesInspected += 1
            if let firstURL = seenPhysicalFiles[identity.physicalID] {
                skipped.append(DuplicateSkippedFile(
                    url: normalizedURL,
                    reason: .hardLink,
                    detail: "Shares storage with \(firstURL.lastPathComponent)"
                ))
            } else {
                seenPhysicalFiles[identity.physicalID] = normalizedURL
                let modifiedAt = try? normalizedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                candidatesBySize[identity.size, default: []].append(Candidate(
                    url: normalizedURL,
                    identity: identity,
                    modifiedAt: modifiedAt
                ))
            }

            if filesInspected == 1 || filesInspected.isMultiple(of: 64) {
                await progress(DuplicateScanProgress(
                    phase: .discovering,
                    filesInspected: filesInspected,
                    filesToHash: 0,
                    filesHashed: 0,
                    bytesHashed: 0,
                    currentURL: normalizedURL
                ))
            }
        }

        try Task.checkCancellation()
        let candidates = candidatesBySize
            .filter { $0.value.count > 1 }
            .values
            .flatMap { $0 }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        var filesByDigest: [DigestKey: [DuplicateFile]] = [:]
        var filesHashed = 0
        var bytesHashed: Int64 = 0

        await progress(DuplicateScanProgress(
            phase: .hashing,
            filesInspected: filesInspected,
            filesToHash: candidates.count,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: candidates.first?.url
        ))

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let digest = try Self.hashFile(at: candidate.url)
                if Self.identity(at: candidate.url) != candidate.identity {
                    skipped.append(DuplicateSkippedFile(url: candidate.url, reason: .changedDuringScan, detail: nil))
                } else {
                    let file = DuplicateFile(
                        url: candidate.url,
                        size: candidate.identity.size,
                        modifiedAt: candidate.modifiedAt,
                        digest: digest,
                        identity: candidate.identity
                    )
                    filesByDigest[DigestKey(size: candidate.identity.size, digest: digest), default: []].append(file)
                    bytesHashed += candidate.identity.size
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(DuplicateSkippedFile(
                    url: candidate.url,
                    reason: .unreadable,
                    detail: error.localizedDescription
                ))
            }
            filesHashed += 1
            await progress(DuplicateScanProgress(
                phase: .hashing,
                filesInspected: filesInspected,
                filesToHash: candidates.count,
                filesHashed: filesHashed,
                bytesHashed: bytesHashed,
                currentURL: candidate.url
            ))
        }

        let groups = filesByDigest.values
            .filter { $0.count > 1 }
            .map { files -> DuplicateGroup in
                let sortedFiles = files.sorted {
                    if $0.modifiedAt != $1.modifiedAt {
                        return ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
                    }
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                return DuplicateGroup(digest: sortedFiles[0].digest, files: sortedFiles)
            }
            .sorted {
                if $0.reclaimableSize != $1.reclaimableSize {
                    return $0.reclaimableSize > $1.reclaimableSize
                }
                return $0.keeper.url.path.localizedStandardCompare($1.keeper.url.path) == .orderedAscending
            }
        let uniqueSkipped = Dictionary(grouping: skipped, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }

        return DuplicateScanResult(
            folder: folder,
            groups: groups,
            skippedFiles: uniqueSkipped,
            filesInspected: filesInspected,
            bytesHashed: bytesHashed
        )
    }

    func moveToTrash(group: DuplicateGroup, selectedIDs: Set<URL>) throws -> DuplicateTrashReport {
        guard !selectedIDs.contains(group.keeper.url) else {
            throw DuplicateFinderError.invalidSelection(group.keeper.url.path)
        }
        let selectedFiles = group.files.filter { selectedIDs.contains($0.url) }
        guard selectedFiles.count == selectedIDs.count else {
            let unknownPath = selectedIDs.first { !group.contains($0) }?.path ?? "Unknown file"
            throw DuplicateFinderError.invalidSelection(unknownPath)
        }
        guard !selectedFiles.isEmpty else {
            return DuplicateTrashReport(trashedFiles: [], failures: [])
        }

        try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
        var selectedPhysicalIDs: Set<DuplicatePhysicalFileID> = [group.keeper.identity.physicalID]
        for file in selectedFiles {
            try Self.validateSelectedFile(file, expectedDigest: group.digest)
            guard selectedPhysicalIDs.insert(file.identity.physicalID).inserted else {
                throw DuplicateFinderError.fileChanged(file.url.path)
            }
        }

        var trashed: [DuplicateFile] = []
        var failures: [DuplicateTrashFailure] = []
        for file in selectedFiles {
            do {
                try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
                try Self.validateSelectedFile(file, expectedDigest: group.digest)
                try preTrashHandler?(file.url)
                try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
                try Self.validateSelectedFile(file, expectedDigest: group.digest)
                try trashHandler(file.url)
                trashed.append(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DuplicateFinderError {
                failures.append(DuplicateTrashFailure(url: file.url, message: error.localizedDescription))
            } catch {
                failures.append(DuplicateTrashFailure(url: file.url, message: error.localizedDescription))
            }
        }
        try Self.validateKeeper(group.keeper, expectedDigest: group.digest)
        return DuplicateTrashReport(trashedFiles: trashed, failures: failures)
    }

    private static func validateKeeper(_ file: DuplicateFile, expectedDigest: String) throws {
        guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
            throw DuplicateFinderError.keeperChanged(file.url.path)
        }
        do {
            guard try hashFile(at: file.url) == expectedDigest else {
                throw DuplicateFinderError.keeperChanged(file.url.path)
            }
            guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
                throw DuplicateFinderError.keeperChanged(file.url.path)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DuplicateFinderError {
            throw error
        } catch {
            throw DuplicateFinderError.keeperChanged(file.url.path)
        }
    }

    private static func validateSelectedFile(_ file: DuplicateFile, expectedDigest: String) throws {
        guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
            throw DuplicateFinderError.fileChanged(file.url.path)
        }
        do {
            guard try hashFile(at: file.url) == expectedDigest else {
                throw DuplicateFinderError.contentChanged(file.url.path)
            }
            guard identity(at: file.url) == file.identity, !isCloudPlaceholder(at: file.url) else {
                throw DuplicateFinderError.fileChanged(file.url.path)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DuplicateFinderError {
            throw error
        } catch {
            throw DuplicateFinderError.fileChanged(file.url.path)
        }
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(at url: URL) -> DuplicateFileIdentity? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return DuplicateFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            flags: information.st_flags
        )
    }

    private static func isRegularFile(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
    }

    private static func isDirectory(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private static func isPackage(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func isCloudPlaceholder(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "icloud" { return true }
        if let identity = identity(at: url), isDatalessFile(flags: identity.flags) { return true }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else { return false }
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
            && values.ubiquitousItemDownloadingStatus != .downloaded
    }

    static func isDatalessFile(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }
}
