import Foundation
import SwiftUI

// MARK: - Sort Field

/// The dimension a file list is ordered by.
///
/// One preference is shared by every list in the app rather than one per
/// screen. The complaint this solves is that sorting was missing or forgotten,
/// not that each screen needed its own memory.
enum FileSortField: String, CaseIterable, Identifiable {
    case name
    case size
    case date
    case path

    var id: String { rawValue }

    /// English source string. Resolved through the standard literal lookup, so
    /// the returned value must exist as a key in every Localizable.strings.
    var label: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .date: return "Date Modified"
        case .path: return "Path"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .size: return "externaldrive"
        case .date: return "calendar"
        case .path: return "folder"
        }
    }

    /// "Largest First" reads better than "Descending" for a cleaner, so each
    /// field names its own directions.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .size: return ascending ? "Smallest First" : "Largest First"
        case .date: return ascending ? "Oldest First" : "Newest First"
        case .name, .path: return ascending ? "A to Z" : "Z to A"
        }
    }

    /// Fields that need a modification date. Lists rendering bare URLs do not
    /// carry one, so they offer the remaining fields only.
    static let fieldsWithoutDate: [FileSortField] = [.name, .size, .path]
}

// MARK: - Sortable

/// Anything a file list can order.
///
/// Views that render bare URLs cannot conform, because size and date do not
/// live on the URL. Those use `FileSort.sortedURLs(_:by:ascending:context:)`.
protocol SortableItem {
    var sortName: String { get }
    var sortSize: Int64 { get }
    var sortDate: Date? { get }
    var sortPath: String { get }
}

extension CleanableItem: SortableItem {
    var sortName: String { name }
    var sortSize: Int64 { size }
    var sortDate: Date? { lastModified }
    var sortPath: String { path }
}

extension Sequence where Element: SortableItem {
    func sorted(by field: FileSortField, ascending: Bool) -> [Element] {
        sorted { FileSort.isOrderedBefore($0, $1, by: field, ascending: ascending) }
    }
}

// MARK: - Comparators

enum FileSort {
    /// Matches the behaviour the size-only toolbar toggle used to default to.
    static let defaultField: FileSortField = .size
    static let defaultAscending = false

    static let fieldPreferenceKey = "settings.sort.field"
    static let ascendingPreferenceKey = "settings.sort.ascending"

    static func isOrderedBefore<T: SortableItem>(
        _ lhs: T,
        _ rhs: T,
        by field: FileSortField,
        ascending: Bool
    ) -> Bool {
        switch field {
        case .name:
            let order = lhs.sortName.localizedStandardCompare(rhs.sortName)
            if order != .orderedSame {
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .path:
            let order = lhs.sortPath.localizedStandardCompare(rhs.sortPath)
            if order != .orderedSame {
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .size:
            if lhs.sortSize != rhs.sortSize {
                return ascending ? lhs.sortSize < rhs.sortSize : lhs.sortSize > rhs.sortSize
            }
        case .date:
            // Undated rows sink to the bottom in both directions so the list
            // never leads with unknowns.
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?):
                if left != right { return ascending ? left < right : left > right }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
        }

        // Stable tie-break. Without it, equal rows shuffle between renders and
        // the removal transitions animate the wrong row out.
        return lhs.sortName.localizedStandardCompare(rhs.sortName) == .orderedAscending
    }
}

// MARK: - URL Lists

extension FileSort {
    /// Sizes and dates for lists that render bare URLs.
    ///
    /// Both callers already keep a size cache built off the main thread, so the
    /// comparator never touches the filesystem. A comparator runs O(n log n)
    /// times, and a cache miss in `AppFilesView` falls through to a live
    /// recursive directory walk, which would beachball the UI.
    struct Context {
        var sizes: [URL: Int64]
        var dates: [URL: Date]

        init(sizes: [URL: Int64] = [:], dates: [URL: Date] = [:]) {
            self.sizes = sizes
            self.dates = dates
        }
    }

    private struct SortableURL: SortableItem {
        let url: URL
        let sortSize: Int64
        let sortDate: Date?

        var sortName: String { url.lastPathComponent }
        var sortPath: String { url.path }
    }

    static func sortedURLs(
        _ urls: [URL],
        by field: FileSortField,
        ascending: Bool,
        context: Context
    ) -> [URL] {
        urls
            .map { SortableURL(url: $0, sortSize: context.sizes[$0] ?? 0, sortDate: context.dates[$0]) }
            .sorted(by: field, ascending: ascending)
            .map(\.url)
    }
}

// MARK: - Table Bridge

extension FileSort {
    /// Feeds the shared preference into the one native `Table` in the app.
    ///
    /// `InstalledApp` has no modification date and the table shows no path
    /// column, so both fall back to the name column.
    static func comparators(
        for field: FileSortField,
        ascending: Bool
    ) -> [KeyPathComparator<InstalledApp>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .size:
            return [KeyPathComparator(\InstalledApp.size, order: order)]
        case .name, .date, .path:
            return [KeyPathComparator(\InstalledApp.appName, order: order)]
        }
    }

    /// Maps a column click back onto the shared preference so the choice
    /// carries over to the other lists.
    static func preference(
        from comparators: [KeyPathComparator<InstalledApp>]
    ) -> (field: FileSortField, ascending: Bool)? {
        guard let first = comparators.first else { return nil }
        let ascending = first.order == .forward

        if first.keyPath == \InstalledApp.size {
            return (.size, ascending)
        }
        if first.keyPath == \InstalledApp.appName {
            return (.name, ascending)
        }
        return nil
    }
}
