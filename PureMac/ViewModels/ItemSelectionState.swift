import Foundation

struct ItemSelectionState {
    private var overrides: [UUID: Bool] = [:]

    func isSelected(_ item: CleanableItem) -> Bool {
        overrides[item.id] ?? item.isSelected
    }

    mutating func toggle(_ item: CleanableItem) {
        setSelected(!isSelected(item), for: item)
    }

    mutating func selectAll(_ items: [CleanableItem]) {
        for item in items {
            setSelected(true, for: item)
        }
    }

    mutating func deselectAll(_ items: [CleanableItem]) {
        for item in items {
            setSelected(false, for: item)
        }
    }

    mutating func clear() {
        overrides.removeAll()
    }

    private mutating func setSelected(_ isSelected: Bool, for item: CleanableItem) {
        if isSelected == item.isSelected {
            overrides.removeValue(forKey: item.id)
        } else {
            overrides[item.id] = isSelected
        }
    }
}
