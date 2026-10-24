enum PurgeScanEvent: Equatable {
    case root(String)
    case walking(String)
    case found(bytes: Int64)
}

struct ScanStatus {
    var headline: String
    var folder: String?
    var foundCount = 0
    var foundBytes: Int64 = 0

    mutating func apply(_ event: PurgeScanEvent) {
        switch event {
        case .root(let path):
            headline = "Scanning " + Render.shorten(path)
            folder = nil
        case .walking(let path):
            folder = path
        case .found(let bytes):
            foundCount += 1
            foundBytes += bytes
        }
    }

    mutating func beginCategory(title: String, position: Int, count: Int) {
        headline = "Scanning \(title), \(position) of \(count)"
    }

    mutating func addFound(in category: CategoryScan) {
        foundCount += category.groups.reduce(0) { $0 + $1.items.count }
        foundBytes += category.allBytes
    }
}
