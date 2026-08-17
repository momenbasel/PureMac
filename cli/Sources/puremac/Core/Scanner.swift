import Foundation

struct ScanItem: Codable {
    let path: String
    let sizeBytes: Int64
    let modified: Date?

    var selected: Bool = true
    var human: String { ByteCount.human(sizeBytes) }
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

    static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(URL(fileURLWithPath: path)) }

        let r = Shell.run("/usr/bin/du", ["-sk", path])
        if r.status == 0 {
            let field = r.out.prefix { $0.isNumber }
            if let kb = Int64(field) {
                let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
                return overflow ? .max : bytes
            }
        }
        return foundationSize(URL(fileURLWithPath: path))
    }

    private static func foundationSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                       options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let item as URL in en { total += fileSize(item) }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        if let a = vals?.totalFileAllocatedSize { return Int64(a) }
        if let a = vals?.fileAllocatedSize { return Int64(a) }
        if let a = vals?.fileSize { return Int64(a) }
        return 0
    }

    static func modified(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}
