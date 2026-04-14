import SwiftUI

// MARK: - Cleaning Category

enum CleaningCategory: String, CaseIterable, Identifiable, Codable {
    case smartScan = "Smart Scan"
    case systemJunk = "System Junk"
    case userCache = "User Cache"
    case mailAttachments = "Mail Files"
    case trashBins = "Trash Bins"
    case largeFiles = "Large & Old Files"
    case purgeableSpace = "Purgeable Space"
    case xcodeJunk = "Xcode Junk"
    case brewCache = "Brew Cache"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles"
        case .systemJunk: return "gearshape.fill"
        case .userCache: return "internaldrive.fill"
        case .mailAttachments: return "envelope.fill"
        case .trashBins: return "trash.fill"
        case .largeFiles: return "doc.fill"
        case .purgeableSpace: return "arrow.3.trianglepath"
        case .xcodeJunk: return "hammer.fill"
        case .brewCache: return "mug.fill"
        }
    }

    var description: String {
        switch self {
        case .smartScan: return "Scan everything at once"
        case .systemJunk: return "System caches, logs, and temporary files"
        case .userCache: return "Application caches and browser data"
        case .mailAttachments: return "Downloaded mail attachments"
        case .trashBins: return "Files in your Trash"
        case .largeFiles: return "Files over 100 MB or older than 1 year"
        case .purgeableSpace: return "APFS purgeable disk space"
        case .xcodeJunk: return "Derived data, archives, and simulators"
        case .brewCache: return "Homebrew download cache"
        }
    }

    var color: Color {
        switch self {
        case .smartScan: return .accentColor
        case .systemJunk: return .purple
        case .userCache: return .blue
        case .mailAttachments: return .orange
        case .trashBins: return .red
        case .largeFiles: return .yellow
        case .purgeableSpace: return .green
        case .xcodeJunk: return .cyan
        case .brewCache: return .mint
        }
    }

    // Categories to scan in Smart Scan mode
    static var scannable: [CleaningCategory] {
        allCases.filter { $0 != .smartScan }
    }
}

// MARK: - Scan State

enum ScanState: Equatable {
    case idle
    case scanning(progress: Double, currentCategory: String)
    case completed
    case cleaning(progress: Double)
    case cleaned

    var isActive: Bool {
        switch self {
        case .scanning, .cleaning: return true
        default: return false
        }
    }
}

// MARK: - Cleanable Item

struct CleanableItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let category: CleaningCategory
    var isSelected: Bool
    let lastModified: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CleanableItem, rhs: CleanableItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Category Result

struct CategoryResult: Identifiable {
    let id = UUID()
    let category: CleaningCategory
    var items: [CleanableItem]
    var totalSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var itemCount: Int { items.count }
}

// MARK: - Schedule Settings

enum ScheduleInterval: String, CaseIterable, Identifiable, Codable {
    case hours1 = "Every Hour"
    case hours3 = "Every 3 Hours"
    case hours6 = "Every 6 Hours"
    case hours12 = "Every 12 Hours"
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hours1: return 3600
        case .hours3: return 10800
        case .hours6: return 21600
        case .hours12: return 43200
        case .daily: return 86400
        case .weekly: return 604800
        case .biweekly: return 1209600
        case .monthly: return 2592000
        }
    }
}

struct ScheduleConfig: Codable {
    var isEnabled: Bool = false
    var interval: ScheduleInterval = .daily
    var autoClean: Bool = false
    var autoPurge: Bool = false
    var categoriesToScan: [CleaningCategory] = CleaningCategory.scannable
    var lastRunDate: Date?
    var nextRunDate: Date?
    var notifyOnCompletion: Bool = true
    var minimumCleanSize: Int64 = 100 * 1024 * 1024 // 100 MB

    var formattedLastRun: String {
        guard let date = lastRunDate else { return String(localized: "Never") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var formattedNextRun: String {
        guard let date = nextRunDate else { return String(localized: "Not scheduled") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Disk Info

struct DiskInfo {
    var totalSpace: Int64 = 0
    var freeSpace: Int64 = 0
    var usedSpace: Int64 = 0
    var purgeableSpace: Int64 = 0

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }

    var freePercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(freeSpace) / Double(totalSpace)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalSpace, countStyle: .file)
    }

    var formattedFree: String {
        ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedSpace, countStyle: .file)
    }

    var formattedPurgeable: String {
        ByteCountFormatter.string(fromByteCount: purgeableSpace, countStyle: .file)
    }
}
