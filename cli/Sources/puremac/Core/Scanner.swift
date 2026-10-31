import Foundation

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ScanItem: Codable {
    let path: String
    let sizeBytes: Int64
    let modified: Date?
    let identity: FileIdentity?

    var selected: Bool = true
    var human: String { ByteCount.human(sizeBytes) }

    init(
        path: String,
        sizeBytes: Int64,
        modified: Date?,
        identity: FileIdentity? = nil,
        selected: Bool = true
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.identity = identity ?? Safety.fileIdentity(at: path)
        self.selected = selected
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes
        case modified
        case selected
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified)
        selected = try values.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        identity = nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(sizeBytes, forKey: .sizeBytes)
        try values.encodeIfPresent(modified, forKey: .modified)
        try values.encode(selected, forKey: .selected)
    }
}

struct ToolGroup: Codable {
    let tool: String
    var items: [ScanItem]
    var totalBytes: Int64 { items.filter { $0.selected }.reduce(0) { $0 + $1.sizeBytes } }
    var allBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

struct CategoryScan: Codable {
    let id: String
    let title: String
    var groups: [ToolGroup]
    var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    var allBytes: Int64 { groups.reduce(0) { $0 + $1.allBytes } }
    var selectedItems: [ScanItem] { groups.flatMap { $0.items }.filter { $0.selected } }
}

enum DirSizer {

    enum Status: String, Codable, Sendable {
        case complete
        case partial
        case unavailable
        case cloudOrDataless
        case symlink
    }

    struct Measurement: Codable, Sendable {
        let bytes: Int64
        let status: Status
        let skippedEntries: Int
    }

    static func size(of path: String) -> Int64 {
        measure(of: path).bytes
    }

    static func measure(of path: String, isCancelled: () -> Bool = { false }) -> Measurement {
        let fm = FileManager.default
        if Safety.hasSymlinkComponent(path) {
            return Measurement(bytes: 0, status: .symlink, skippedEntries: 1)
        }
        if Safety.isCloudOrDataless(path) {
            return Measurement(bytes: 0, status: .cloudOrDataless, skippedEntries: 1)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return Measurement(bytes: 0, status: .unavailable, skippedEntries: 1)
        }
        if !isDir.boolValue {
            guard let bytes = fileSize(URL(fileURLWithPath: path)) else {
                return Measurement(bytes: 0, status: .unavailable, skippedEntries: 1)
            }
            return Measurement(bytes: bytes, status: .complete, skippedEntries: 0)
        }
        return foundationSize(URL(fileURLWithPath: path), isCancelled: isCancelled)
    }

    private static func foundationSize(_ url: URL, isCancelled: () -> Bool) -> Measurement {
        var total: Int64 = 0
        var skipped = 0
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                       options: [], errorHandler: { _, _ in
            skipped += 1
            return true
        }) else {
            return Measurement(bytes: 0, status: .unavailable, skippedEntries: 1)
        }
        for case let item as URL in en {
            if isCancelled() {
                return Measurement(bytes: total, status: .partial, skippedEntries: skipped + 1)
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                en.skipDescendants()
                continue
            }
            if Safety.isCloudOrDataless(item.path) {
                if values?.isDirectory == true { en.skipDescendants() }
                skipped += 1
                continue
            }
            guard values?.isRegularFile == true, let bytes = fileSize(item, values: values) else { continue }
            let (next, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? .max : next
        }
        return Measurement(bytes: total, status: skipped == 0 ? .complete : .partial, skippedEntries: skipped)
    }

    private static func fileSize(_ url: URL, values: URLResourceValues? = nil) -> Int64? {
        let vals = values ?? (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]))
        if let a = vals?.totalFileAllocatedSize { return Int64(a) }
        if let a = vals?.fileAllocatedSize { return Int64(a) }
        if let a = vals?.fileSize { return Int64(a) }
        return nil
    }

    static func modified(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}
