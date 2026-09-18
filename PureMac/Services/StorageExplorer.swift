import Darwin
import Foundation

struct StorageEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case file
        case directory
        case package
    }

    let url: URL
    let kind: Kind
    let allocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let inaccessibleCount: Int
    let skippedCount: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isDirectory: Bool { kind == .directory }
    var isPackage: Bool { kind == .package }
    var isPartial: Bool { inaccessibleCount > 0 || skippedCount > 0 }
    var itemCount: Int { fileCount + directoryCount }
}

struct StorageScanProgress: Sendable {
    let rootURL: URL
    let currentURL: URL
    let allocatedSize: Int64
    let scannedItemCount: Int
    let inaccessibleCount: Int
    let skippedCount: Int
}

struct StorageScanResult: Sendable {
    let rootURL: URL
    let entries: [StorageEntry]
    let totalAllocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let inaccessibleCount: Int
    let skippedCount: Int

    var scannedItemCount: Int { fileCount + directoryCount }
    var isPartial: Bool { inaccessibleCount > 0 || skippedCount > 0 }
}

enum StorageExplorerError: LocalizedError, Equatable {
    case notDirectory(String)
    case symbolicLink(String)
    case package(String)
    case cloudOnly(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            return String(localized: "The selected item is not a folder: \(path)")
        case .symbolicLink(let path):
            return String(localized: "Symbolic links cannot be scanned: \(path)")
        case .package(let path):
            return String(localized: "App and document packages are excluded: \(path)")
        case .cloudOnly(let path):
            return String(localized: "The selected folder is stored in the cloud and has not been downloaded: \(path)")
        case .unavailable(let path):
            return String(localized: "The selected folder could not be read: \(path)")
        }
    }
}

actor StorageExplorer {
    typealias ProgressHandler = @Sendable (StorageScanProgress) -> Void

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileMetadata {
        let identity: FileIdentity
        let allocatedSize: Int64
        let isDataless: Bool
    }

    private struct ScanContext {
        var allocatedSize: Int64 = 0
        var fileCount = 0
        var directoryCount = 0
        var inaccessibleCount = 0
        var skippedCount = 0
        var seenFiles: Set<FileIdentity> = []
    }

    private struct EntryMeasure {
        var allocatedSize: Int64 = 0
        var fileCount = 0
        var directoryCount = 0
        var inaccessibleCount = 0
        var skippedCount = 0
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    func scan(
        at selectedURL: URL,
        progress: ProgressHandler? = nil
    ) async throws -> StorageScanResult {
        try Task.checkCancellation()

        let rootURL = selectedURL.standardizedFileURL
        let rootValues: URLResourceValues
        do {
            rootValues = try rootURL.resourceValues(forKeys: Self.resourceKeys)
        } catch {
            throw StorageExplorerError.unavailable(rootURL.path)
        }

        guard rootValues.isSymbolicLink != true else {
            throw StorageExplorerError.symbolicLink(rootURL.path)
        }
        guard rootValues.isPackage != true else {
            throw StorageExplorerError.package(rootURL.path)
        }
        guard rootValues.isDirectory == true else {
            throw StorageExplorerError.notDirectory(rootURL.path)
        }
        guard !Self.isUnavailableCloudItem(rootValues) else {
            throw StorageExplorerError.cloudOnly(rootURL.path)
        }
        guard let rootMetadata = Self.metadata(for: rootURL) else {
            throw StorageExplorerError.unavailable(rootURL.path)
        }
        guard !rootMetadata.isDataless else {
            throw StorageExplorerError.cloudOnly(rootURL.path)
        }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
        } catch {
            throw StorageExplorerError.unavailable(rootURL.path)
        }

        var context = ScanContext()
        var entries: [StorageEntry] = []
        let orderedChildren = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        for child in orderedChildren {
            try Task.checkCancellation()
            if let entry = try measure(
                child,
                rootURL: rootURL,
                context: &context,
                progress: progress
            ) {
                entries.append(entry)
            }
        }

        entries.sort {
            if $0.allocatedSize == $1.allocatedSize {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.allocatedSize > $1.allocatedSize
        }

        progress?(
            StorageScanProgress(
                rootURL: rootURL,
                currentURL: rootURL,
                allocatedSize: context.allocatedSize,
                scannedItemCount: context.fileCount + context.directoryCount,
                inaccessibleCount: context.inaccessibleCount,
                skippedCount: context.skippedCount
            )
        )

        return StorageScanResult(
            rootURL: rootURL,
            entries: entries,
            totalAllocatedSize: context.allocatedSize,
            fileCount: context.fileCount,
            directoryCount: context.directoryCount,
            inaccessibleCount: context.inaccessibleCount,
            skippedCount: context.skippedCount
        )
    }

    private func measure(
        _ topURL: URL,
        rootURL: URL,
        context: inout ScanContext,
        progress: ProgressHandler?
    ) throws -> StorageEntry? {
        var stack = [topURL]
        var entryMeasure = EntryMeasure()
        var topKind: StorageEntry.Kind?

        while let url = stack.popLast() {
            try Task.checkCancellation()

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                context.inaccessibleCount += 1
                entryMeasure.inaccessibleCount += 1
                continue
            }

            if values.isSymbolicLink == true || Self.isUnavailableCloudItem(values) {
                context.skippedCount += 1
                entryMeasure.skippedCount += 1
                continue
            }

            guard let metadata = Self.metadata(for: url) else {
                context.inaccessibleCount += 1
                entryMeasure.inaccessibleCount += 1
                continue
            }
            if metadata.isDataless {
                context.skippedCount += 1
                entryMeasure.skippedCount += 1
                continue
            }

            if values.isDirectory == true {
                if url == topURL {
                    topKind = values.isPackage == true ? .package : .directory
                }
                context.allocatedSize += metadata.allocatedSize
                context.directoryCount += 1
                entryMeasure.allocatedSize += metadata.allocatedSize
                entryMeasure.directoryCount += 1

                do {
                    let children = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: Array(Self.resourceKeys),
                        options: []
                    )
                    stack.append(contentsOf: children)
                } catch {
                    context.inaccessibleCount += 1
                    entryMeasure.inaccessibleCount += 1
                }
            } else if values.isRegularFile == true {
                if url == topURL {
                    topKind = .file
                }
                if context.seenFiles.insert(metadata.identity).inserted {
                    context.allocatedSize += metadata.allocatedSize
                    context.fileCount += 1
                    entryMeasure.allocatedSize += metadata.allocatedSize
                    entryMeasure.fileCount += 1
                } else {
                    context.skippedCount += 1
                    entryMeasure.skippedCount += 1
                }
            } else {
                context.skippedCount += 1
                entryMeasure.skippedCount += 1
            }

            let scannedCount = context.fileCount + context.directoryCount
            if scannedCount > 0 && scannedCount.isMultiple(of: 64) {
                progress?(
                    StorageScanProgress(
                        rootURL: rootURL,
                        currentURL: url,
                        allocatedSize: context.allocatedSize,
                        scannedItemCount: scannedCount,
                        inaccessibleCount: context.inaccessibleCount,
                        skippedCount: context.skippedCount
                    )
                )
            }
        }

        guard let topKind, entryMeasure.fileCount + entryMeasure.directoryCount > 0 else { return nil }
        return StorageEntry(
            url: topURL,
            kind: topKind,
            allocatedSize: entryMeasure.allocatedSize,
            fileCount: entryMeasure.fileCount,
            directoryCount: entryMeasure.directoryCount,
            inaccessibleCount: entryMeasure.inaccessibleCount,
            skippedCount: entryMeasure.skippedCount
        )
    }

    private static func isUnavailableCloudItem(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else { return false }
        let status = values.ubiquitousItemDownloadingStatus
        return status != .current && status != .downloaded
    }

    private static func metadata(for url: URL) -> FileMetadata? {
        var fileStat = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &fileStat)
        }
        guard status == 0 else { return nil }

        let blocks = max(Int64(0), Int64(fileStat.st_blocks))
        return FileMetadata(
            identity: FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino)),
            allocatedSize: blocks * 512,
            isDataless: fileStat.st_flags & UInt32(SF_DATALESS) != 0
        )
    }
}
