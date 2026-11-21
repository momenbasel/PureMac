import Foundation

/// Allocated-size calculation that works for both files and directories.
/// Full APFS clone groups are counted once within a scanned tree.
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
        if let metadata = FileAllocation.metadata(at: url) {
            return metadata.allocatedBytes
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return size
    }

    /// Sum of regular-file allocations under `url`. Symlinks are never
    /// followed; hard links and full APFS clone groups count once.
    /// Unreadable entries are skipped instead of aborting the walk, and
    /// task cancellation stops it early. `onEntry` sees every visited URL.
    static func directorySize(
        of url: URL,
        includeHidden: Bool = false,
        onEntry: (URL) -> Void = { _ in }
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [],
            options: includeHidden ? [] : [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var seenFiles: Set<FileAllocation.Identity> = []
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            onEntry(fileURL)
            // lstat-based type check: symlinks and special files are skipped.
            guard let metadata = FileAllocation.metadata(at: fileURL),
                  metadata.isRegularFile,
                  seenFiles.insert(metadata.identity).inserted else { continue }
            total += metadata.allocatedBytes
        }
        return total
    }
}
