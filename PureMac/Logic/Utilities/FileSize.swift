import Darwin
import Foundation

/// Allocated-size calculation that works for both files and directories.
///
/// `URLResourceValues.totalFileAllocatedSize` does **not** recurse: on a
/// directory URL it returns only the directory inode's own allocation
/// (~96 bytes to a few KB on APFS), not the sum of the bundle's contents.
/// Reading it directly on an `.app` bundle or a support folder is what made
/// items display as a handful of bytes. For directories we enumerate and sum
/// the regular files instead.
enum FileSizeCalculator {
    private static let fileManager = FileManager.default

    /// On-disk allocated size of `url`. Recurses into directories.
    /// Returns `nil` if the item can't be read at all.
    static func size(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Treat a symlink as a file (size of the link itself), never recursing
        // into its target. `.isDirectoryKey` resolves symlinks, so without this
        // guard a top-level symlink-to-directory would be walked as the target's
        // full tree — inflating the size, escaping the item's real footprint,
        // and mismatching deletion (removeItem deletes only the link). Check
        // isSymbolicLink first so the directory branch only sees real dirs.
        if values?.isSymbolicLink != true, values?.isDirectory == true {
            return directorySize(of: url)
        }
        return fileSize(of: url)
    }

    private static func fileSize(of url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let size = values.totalFileAllocatedSize {
            return Int64(size)
        }
        if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]),
           let size = values.fileAllocatedSize {
            return Int64(size)
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return size
    }

    static func directorySize(
        of url: URL,
        includeHidden: Bool = false,
        onEntry: (URL) -> Void = { _ in }
    ) -> Int64 {
        guard let root = FileAllocation(at: url), root.isDirectory, !root.isDataless else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [],
            options: includeHidden ? [] : [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var ledger = FileAllocation.Ledger()
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            onEntry(fileURL)
            guard let allocation = FileAllocation(at: fileURL) else { continue }
            if allocation.isDataless {
                if allocation.isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard allocation.isRegularFile, let bytes = ledger.additionalBytes(for: allocation) else { continue }
            total += bytes
        }
        return total
    }
}

struct FileAllocation {
    private struct Identity: Hashable {
        let device: dev_t
        let id: UInt64
    }

    struct Ledger {
        private var linkedFiles: Set<Identity> = []
        private var cloneGroups: Set<Identity> = []

        mutating func additionalBytes(for allocation: FileAllocation) -> Int64? {
            if let link = allocation.hardLink, !linkedFiles.insert(link).inserted {
                return nil
            }
            if let data = allocation.sharedData, !cloneGroups.insert(data.id).inserted {
                return allocation.bytes - data.bytes
            }
            return allocation.bytes
        }
    }

    private let hardLink: Identity?
    private let sharedData: (id: Identity, bytes: Int64)?
    let isRegularFile: Bool
    let isDirectory: Bool
    let isDataless: Bool
    let bytes: Int64

    init?(at url: URL) {
        guard let allocation = url.withUnsafeFileSystemRepresentation({ path in
            path.flatMap { FileAllocation(atPath: $0) }
        }) else { return nil }
        self = allocation
    }

    private init?(atPath path: UnsafePointer<CChar>) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        isRegularFile = type == S_IFREG
        isDirectory = type == S_IFDIR
        isDataless = info.st_flags & UInt32(SF_DATALESS) != 0
        bytes = max(0, Int64(info.st_blocks)) * 512
        hardLink = isRegularFile && info.st_nlink > 1 ? Identity(device: info.st_dev, id: info.st_ino) : nil
        if isRegularFile && bytes > 0 && !isDataless, let stream = Self.sharedDataStream(atPath: path) {
            sharedData = (Identity(device: info.st_dev, id: stream.id), min(bytes, stream.bytes))
        } else {
            sharedData = nil
        }
    }

    private static func sharedDataStream(atPath path: UnsafePointer<CChar>) -> (id: UInt64, bytes: Int64)? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATAALLOCSIZE)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)

        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 7) { storage in
            let buffer = UnsafeMutableRawBufferPointer(storage)
            let status = getattrlist(path, &attributes, buffer.baseAddress, buffer.count,
                                     UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
            guard status == 0, storage[0] == UInt32(buffer.count) else { return nil }
            let dataBytes = buffer.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            let cloneID = buffer.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
            let flags = buffer.loadUnaligned(fromByteOffset: 20, as: UInt64.self)
            guard dataBytes > 0, cloneID != 0, flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 else { return nil }
            return (cloneID, dataBytes)
        }
    }
}
