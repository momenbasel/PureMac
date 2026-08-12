import Foundation

/// Incremental list updates after deleting extension-related paths — avoids a
/// full `~/.*/extensions` rescan (which can take many seconds with hundreds of installs).
enum VSCodeExtensionListUpdater {
    struct Result: Equatable {
        var extensions: [VSCodeExtensionItem]
        /// Selection after removal: kept item, neighbor when install dir gone, or nil.
        var selected: VSCodeExtensionItem?
    }

    static func applyingRemoval(
        extensions: [VSCodeExtensionItem],
        selected: VSCodeExtensionItem?,
        removedPaths: [URL],
        neighborOrder: [VSCodeExtensionItem]? = nil
    ) -> Result {
        let removed = Set(removedPaths.map { ($0.path as NSString).standardizingPath })
        let remaining = extensions.filter { item in
            !removed.contains((item.path as NSString).standardizingPath)
        }
        let remainingById = Dictionary(uniqueKeysWithValues: remaining.map { ($0.id, $0) })

        guard let selected else {
            return Result(extensions: remaining, selected: nil)
        }

        let selectedPath = (selected.path as NSString).standardizingPath
        if !removed.contains(selectedPath) {
            return Result(extensions: remaining, selected: remainingById[selected.id] ?? selected)
        }

        let order = neighborOrder ?? extensions
        let next = neighbor(
            of: selected.id,
            in: order,
            remainingIds: Set(remainingById.keys)
        ).flatMap { remainingById[$0] }

        return Result(extensions: remaining, selected: next)
    }

    /// Prefer the next row in display order; if none, the previous row.
    private static func neighbor(
        of selectedId: VSCodeExtensionItem.ID,
        in order: [VSCodeExtensionItem],
        remainingIds: Set<VSCodeExtensionItem.ID>
    ) -> VSCodeExtensionItem.ID? {
        guard let idx = order.firstIndex(where: { $0.id == selectedId }) else {
            return order.first(where: { remainingIds.contains($0.id) })?.id
        }
        if let after = order[(idx + 1)...].first(where: { remainingIds.contains($0.id) }) {
            return after.id
        }
        return order[..<idx].last(where: { remainingIds.contains($0.id) })?.id
    }
}
