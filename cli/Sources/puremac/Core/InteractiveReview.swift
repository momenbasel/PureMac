import Foundation

struct ReviewAddress: Hashable {
    let category: Int
    let group: Int
    let item: Int
}

enum ReviewDisplayRow {
    case category(Int)
    case group(category: Int, group: Int)
    case item(ReviewAddress)
}

struct InteractiveReviewModel {
    var categories: [CategoryScan]
    var query = ""
    var isSearching = false
    var isReviewing = false
    var status = ""
    var pathOffset = 0
    private(set) var focus = 0
    private(set) var reviewFocus = 0

    init(categories: [CategoryScan]) {
        self.categories = categories.map { category in
            var copy = category
            copy.groups = copy.groups.map { group in
                var groupCopy = group
                groupCopy.items = groupCopy.items.map { item in
                    var itemCopy = item
                    itemCopy.selected = false
                    return itemCopy
                }
                return groupCopy
            }
            return copy
        }
    }

    var matchingAddresses: [ReviewAddress] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var addresses: [ReviewAddress] = []
        for categoryIndex in categories.indices {
            let category = categories[categoryIndex]
            for groupIndex in category.groups.indices {
                let group = category.groups[groupIndex]
                for itemIndex in group.items.indices {
                    let item = group.items[itemIndex]
                    let searchable = "\(category.title) \(group.tool) \(item.path)".lowercased()
                    if needle.isEmpty || searchable.contains(needle) {
                        addresses.append(
                            ReviewAddress(
                                category: categoryIndex,
                                group: groupIndex,
                                item: itemIndex
                            )
                        )
                    }
                }
            }
        }
        return addresses
    }

    var selectedAddresses: [ReviewAddress] {
        allAddresses.filter { item(at: $0).selected }
    }

    var selectedCount: Int {
        selectedAddresses.count
    }

    var selectedBytes: Int64 {
        selectedAddresses.reduce(Int64(0)) { $0 + item(at: $1).sizeBytes }
    }

    var allBytes: Int64 {
        categories.reduce(Int64(0)) { $0 + $1.allBytes }
    }

    var focusedAddress: ReviewAddress? {
        let addresses = isReviewing ? selectedAddresses : matchingAddresses
        let index = isReviewing ? reviewFocus : focus
        guard addresses.indices.contains(index) else { return nil }
        return addresses[index]
    }

    mutating func move(_ delta: Int) {
        let count = isReviewing ? selectedAddresses.count : matchingAddresses.count
        guard count > 0 else { return }
        if isReviewing {
            reviewFocus = min(count - 1, max(0, reviewFocus + delta))
        } else {
            focus = min(count - 1, max(0, focus + delta))
        }
        pathOffset = 0
    }

    mutating func moveToStart() {
        if isReviewing {
            reviewFocus = 0
        } else {
            focus = 0
        }
        pathOffset = 0
    }

    mutating func moveToEnd() {
        if isReviewing {
            reviewFocus = max(0, selectedAddresses.count - 1)
        } else {
            focus = max(0, matchingAddresses.count - 1)
        }
        pathOffset = 0
    }

    mutating func toggleFocused() {
        guard !isReviewing, let address = focusedAddress else { return }
        categories[address.category].groups[address.group].items[address.item].selected.toggle()
    }

    mutating func selectAllMatching() {
        for address in matchingAddresses {
            categories[address.category].groups[address.group].items[address.item].selected = true
        }
        status = matchingAddresses.isEmpty ? "No matching items" : "Selected visible items"
    }

    mutating func selectNone() {
        for address in allAddresses {
            categories[address.category].groups[address.group].items[address.item].selected = false
        }
        reviewFocus = 0
        status = "Selection cleared"
    }

    mutating func updateQuery(_ value: String) {
        query = value
        focus = 0
        pathOffset = 0
        status = ""
    }

    mutating func beginReview() -> Bool {
        guard selectedCount > 0 else {
            status = "Select at least one item to continue"
            return false
        }
        isReviewing = true
        reviewFocus = 0
        pathOffset = 0
        status = ""
        return true
    }

    mutating func endReview() {
        isReviewing = false
        pathOffset = 0
        status = ""
    }

    func displayRows(reviewing: Bool) -> [ReviewDisplayRow] {
        let addresses = reviewing ? selectedAddresses : matchingAddresses
        var rows: [ReviewDisplayRow] = []
        var lastCategory: Int?
        var lastGroup: Int?
        for address in addresses {
            if lastCategory != address.category {
                rows.append(.category(address.category))
                lastCategory = address.category
                lastGroup = nil
            }
            if lastGroup != address.group {
                rows.append(.group(category: address.category, group: address.group))
                lastGroup = address.group
            }
            rows.append(.item(address))
        }
        return rows
    }

    func item(at address: ReviewAddress) -> ScanItem {
        categories[address.category].groups[address.group].items[address.item]
    }

    func selectedResult() -> [CategoryScan] {
        categories
    }

    private var allAddresses: [ReviewAddress] {
        var addresses: [ReviewAddress] = []
        for categoryIndex in categories.indices {
            for groupIndex in categories[categoryIndex].groups.indices {
                for itemIndex in categories[categoryIndex].groups[groupIndex].items.indices {
                    addresses.append(
                        ReviewAddress(
                            category: categoryIndex,
                            group: groupIndex,
                            item: itemIndex
                        )
                    )
                }
            }
        }
        return addresses
    }
}

enum InteractiveReview {
    static func select(_ categories: [CategoryScan], title: String) throws -> [CategoryScan]? {
        let session = try TerminalSession()
        defer { session.close() }

        var model = InteractiveReviewModel(categories: categories)
        while true {
            session.draw(lines: render(model: model, title: title, width: session.width, height: session.height))
            let key = session.readKey()

            if model.isSearching {
                switch key {
                case .enter:
                    model.isSearching = false
                case .escape:
                    model.isSearching = false
                    model.updateQuery("")
                case .backspace, .delete:
                    if !model.query.isEmpty {
                        model.updateQuery(String(model.query.dropLast()))
                    }
                case .space:
                    model.updateQuery(model.query + " ")
                case .character(let character):
                    if !character.isASCIIControl {
                        model.updateQuery(model.query + String(character))
                    }
                default:
                    break
                }
                continue
            }

            switch key {
            case .up:
                model.move(-1)
            case .down:
                model.move(1)
            case .pageUp:
                model.move(-max(1, session.height / 2))
            case .pageDown:
                model.move(max(1, session.height / 2))
            case .home:
                model.moveToStart()
            case .end:
                model.moveToEnd()
            case .left:
                model.pathOffset = max(0, model.pathOffset - max(8, session.width / 3))
            case .right:
                model.pathOffset += max(8, session.width / 3)
            case .space:
                model.toggleFocused()
            case .enter:
                if model.isReviewing {
                    return model.selectedResult()
                }
                _ = model.beginReview()
            case .escape:
                if model.isReviewing {
                    model.endReview()
                } else {
                    return nil
                }
            case .character(let character):
                switch character.lowercasedString {
                case "a":
                    if !model.isReviewing { model.selectAllMatching() }
                case "n":
                    if !model.isReviewing { model.selectNone() }
                case "/":
                    if !model.isReviewing {
                        model.isSearching = true
                        model.status = ""
                    }
                case "q":
                    return nil
                default:
                    break
                }
            default:
                break
            }
        }
    }

    static func render(
        model: InteractiveReviewModel,
        title: String,
        width: Int,
        height: Int
    ) -> [String] {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        if safeWidth < 40 || safeHeight < 12 {
            return compactScreen(width: safeWidth, height: safeHeight)
        }
        let titleText = Term.truncate(title, to: safeWidth - 2)
        let selection = "\(model.selectedCount) selected · \(ByteCount.human(model.selectedBytes))"
        let found = "\(model.matchingAddresses.count) shown · \(ByteCount.human(model.allBytes))"
        var lines = [
            Term.dim("PUREMAC  /  \(model.isReviewing ? "FINAL REVIEW" : "SELECT ITEMS")"),
            Term.bold(Term.cyan(titleText)),
            statusLine(left: found, right: selection, width: safeWidth)
        ]

        if model.isSearching {
            let query = Term.truncate(model.query, to: max(1, safeWidth - 10))
            lines.append(Term.cyan("Search  ") + query + Term.inverse(" "))
        } else if !model.status.isEmpty {
            lines.append(Term.yellow(Term.truncate(model.status, to: safeWidth)))
        } else if model.query.isEmpty {
            lines.append("")
        } else {
            lines.append(Term.dim("Filter  ") + Term.truncate(model.query, to: max(1, safeWidth - 9)))
        }

        let footerHeight = 5
        let bodyHeight = max(3, safeHeight - lines.count - footerHeight)
        let rows = model.displayRows(reviewing: model.isReviewing)
        let focusedAddress = model.focusedAddress
        let focusedRow = rows.firstIndex { row in
            if case .item(let address) = row { return address == focusedAddress }
            return false
        } ?? 0
        let start = max(0, min(max(0, rows.count - bodyHeight), focusedRow - bodyHeight / 2))
        let visibleRows = rows.dropFirst(start).prefix(bodyHeight)

        for row in visibleRows {
            switch row {
            case .category(let categoryIndex):
                let category = model.categories[categoryIndex]
                let label = Term.truncate(Term.sanitize(category.title).uppercased(), to: safeWidth - 4)
                lines.append("  " + Term.bold(Term.cyan(label)))
            case .group(let categoryIndex, let groupIndex):
                let group = model.categories[categoryIndex].groups[groupIndex]
                let suffix = "\(group.items.count) \(group.items.count == 1 ? "item" : "items")"
                let available = max(1, safeWidth - 8 - suffix.count)
                lines.append("    " + Term.dim(Term.pad(Term.truncate(group.tool, to: available), to: available) + suffix))
            case .item(let address):
                let item = model.item(at: address)
                let focused = address == focusedAddress
                let mark = item.selected ? Term.cyan("●") : Term.dim("○")
                let pointer = focused ? Term.cyan("›") : " "
                let size = Term.pad(ByteCount.human(item.sizeBytes), to: 10)
                let noteText = item.note.map { "  [\(Term.sanitize($0))]" } ?? ""
                let pathWidth = max(6, safeWidth - 17 - noteText.count)
                let path = Term.truncate(Render.shorten(item.path), to: pathWidth, middle: true)
                let content = "\(pointer) \(mark) \(size) \(path)\(noteText)"
                lines.append(focused ? Term.inverse(content) : content)
            }
        }

        while lines.count < safeHeight - footerHeight {
            lines.append("")
        }

        let divider = String(repeating: "─", count: safeWidth)
        lines.append(Term.dim(divider))
        lines.append(focusedPathLine(model: model, width: safeWidth))
        if model.isReviewing {
            lines.append(Term.dim("↑↓ scroll  ←→ path"))
            lines.append(Term.dim("Enter confirm  Esc edit"))
            lines.append(Term.yellow("q cancel  command confirmation follows"))
        } else {
            lines.append(Term.dim("↑↓ move  ←→ path  Space toggle"))
            lines.append(Term.dim("A all  N none  / search"))
            lines.append(Term.dim("Enter review  Esc/q cancel"))
        }
        return Array(lines.prefix(safeHeight))
    }

    private static func compactScreen(width: Int, height: Int) -> [String] {
        let lines = [
            Term.bold(Term.cyan(Term.truncate("PureMac", to: width))),
            Term.truncate("Terminal too small", to: width),
            Term.dim(Term.truncate("Resize to at least 40 x 12", to: width)),
            "",
            Term.dim(Term.truncate("Esc/q cancel", to: width))
        ]
        return Array(lines.prefix(height))
    }

    static func statusLine(left: String, right: String, width: Int) -> String {
        let available = max(1, width - 2)
        let leftWidth = Term.displayWidth(left)
        let rightWidth = Term.displayWidth(right)
        if leftWidth + rightWidth <= available {
            return Term.pad(left, to: available - rightWidth) + "  " + Term.bold(right)
        }

        let rightBudget = min(rightWidth, max(1, available / 2))
        let leftBudget = max(1, available - rightBudget)
        let clippedLeft = Term.truncate(left, to: leftBudget)
        let clippedRight = Term.truncate(right, to: rightBudget)
        return Term.pad(clippedLeft, to: leftBudget) + "  " + Term.bold(clippedRight)
    }

    private static func focusedPathLine(model: InteractiveReviewModel, width: Int) -> String {
        guard let address = model.focusedAddress else {
            return Term.dim("Path  No matching item")
        }
        let path = Render.shorten(model.item(at: address).path)
        let available = max(1, width - 6)
        let window = horizontalWindow(path, offset: model.pathOffset, width: available)
        return Term.dim("Path  ") + window
    }

    static func horizontalWindow(_ value: String, offset: Int, width: Int) -> String {
        let safe = Term.sanitize(value)
        let characters = Array(safe)
        let start = min(max(0, offset), characters.count)
        let prefixMarker = start > 0 ? "‹" : ""
        var output = ""
        var used = Term.displayWidth(prefixMarker)
        var index = start

        while index < characters.count {
            let value = String(characters[index])
            let characterWidth = Term.displayWidth(value)
            let remainingMarker = index + 1 < characters.count ? 1 : 0
            guard used + characterWidth + remainingMarker <= width else { break }
            output.append(characters[index])
            used += characterWidth
            index += 1
        }
        let suffixMarker = index < characters.count ? "›" : ""
        return prefixMarker + output + suffixMarker
    }
}

private extension Character {
    var isASCIIControl: Bool {
        unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F }
    }

    var lowercasedString: String {
        String(self).lowercased()
    }
}
