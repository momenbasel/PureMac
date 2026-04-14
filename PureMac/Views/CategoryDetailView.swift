import SwiftUI


struct CategoryDetailView: View {
    @EnvironmentObject var vm: AppViewModel
    let category: CleaningCategory

    @State private var filter = FilterConfig()

    var result: CategoryResult? {
        vm.categoryResults[category]
    }

    var filteredItems: [CleanableItem] {
        guard let items = result?.items else { return [] }

        let filtered = items.filter { filter.matches($0) }

        return filtered.sorted { a, b in
            let ascending = filter.sortOrder == .ascending
            switch filter.sortBy {
            case .size:
                return ascending ? a.size < b.size : a.size > b.size
            case .date:
                let d1 = a.lastModified ?? Date.distantPast
                let d2 = b.lastModified ?? Date.distantPast
                return ascending ? d1 < d2 : d1 > d2
            case .name:
                return ascending ? a.name < b.name : a.name > b.name
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Category header
            categoryHeader
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 16)

            if let result = result {
                if result.items.isEmpty {
                    emptyState
                } else {
                    // Search & Filter Bar
                    filterBar
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)

                    // File list
                    fileList(result)
                }
            } else {
                // Not scanned yet
                notScannedState
            }

            Spacer()

            // Action bar
            categoryActionBar
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Header

    private var categoryHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(category.color.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: category.icon)
                    .font(.system(size: 22))
                    .foregroundColor(category.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.pmHeadline)
                    .foregroundColor(.pmTextPrimary)

                Text(LocalizedStringKey(category.description))
                    .font(.pmCaption)
                    .foregroundColor(.pmTextSecondary)
            }

            Spacer()

            if let result = result {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(result.formattedSize)
                        .font(.pmMediumNumber)
                        .foregroundColor(category.color)

                    Text("\(result.itemCount) items")
                        .font(.pmCaption)
                        .foregroundColor(.pmTextMuted)
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.pmTextMuted)
                    .font(.system(size: 12))
                TextField("Search files...", text: $filter.searchText)
                    .textFieldStyle(.plain)
                    .font(.pmBody)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.pmCard)
            .cornerRadius(8)
            .frame(maxWidth: .infinity)

            // Size Filter
            filterMenu(title: filter.sizeFilter == .all ? "Size" : filter.sizeFilter.rawValue, icon: "line.3.horizontal.decrease.circle") {
                Picker("Size", selection: $filter.sizeFilter) {
                    ForEach(SizeFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
            }

            // Date Filter
            filterMenu(title: filter.dateFilter == .all ? "Date" : filter.dateFilter.rawValue, icon: "calendar") {
                Picker("Date", selection: $filter.dateFilter) {
                    ForEach(DateFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
            }

            // Sort
            Menu {
                Picker("Sort By", selection: $filter.sortBy) {
                    ForEach(SortBy.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                Divider()
                Button(action: { filter.sortOrder = .ascending }) {
                    HStack {
                        Text("Ascending")
                        if filter.sortOrder == .ascending { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { filter.sortOrder = .descending }) {
                    HStack {
                        Text("Descending")
                        if filter.sortOrder == .descending { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                    .foregroundColor(.pmTextSecondary)
                    .padding(8)
                    .background(Color.pmCard)
                    .cornerRadius(8)
            }
            .menuStyle(.plain)
        }
    }

    private func filterMenu<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.pmTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.pmCard)
            .cornerRadius(8)
        }
        .menuStyle(.plain)
    }

    // MARK: - File List

    private func fileList(_ result: CategoryResult) -> some View {
        VStack(spacing: 0) {
            // Select all / Deselect all bar
            HStack(spacing: 16) {
                let items = filteredItems
                let selectedCount = items.filter { vm.isItemSelected($0) }.count
                let totalCount = items.count

                Text("\(selectedCount) of \(totalCount) selected")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.pmTextMuted)

                Spacer()

                Button("Select All") {
                    vm.selectItems(items)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.pmAccentLight)
                .buttonStyle(.plain)

                Text("|")
                    .foregroundColor(.pmSeparator)
                    .font(.system(size: 11))

                Button("Deselect All") {
                    vm.deselectItems(items)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.pmAccentLight)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 8)

            Divider()
                .background(Color.pmSeparator)
                .padding(.horizontal, 32)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredItems) { item in
                        FileRow(item: item, color: category.color)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Empty / Not Scanned

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.pmSuccess)

            Text("All Clean!")
                .font(.pmHeadline)
                .foregroundColor(.pmTextPrimary)

            Text("No junk files found in this category.")
                .font(.pmBody)
                .foregroundColor(.pmTextSecondary)
            Spacer()
        }
    }

    private var notScannedState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(category.color.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: category.icon)
                    .font(.system(size: 40))
                    .foregroundColor(category.color.opacity(0.5))
            }

            Text("Not scanned yet")
                .font(.pmSubheadline)
                .foregroundColor(.pmTextSecondary)

            Text("Click Scan to analyze this category")
                .font(.pmCaption)
                .foregroundColor(.pmTextMuted)
            Spacer()
        }
    }

    // MARK: - Action Bar

    private var categoryActionBar: some View {
        HStack(spacing: 16) {
            if result == nil || vm.scanState == .idle || vm.scanState == .completed {
                GradientActionButton(
                    title: "Scan",
                    icon: "magnifyingglass",
                    gradient: LinearGradient(
                        colors: [category.color, category.color.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                ) {
                    withAnimation(.pmSpring) {
                        vm.scanSingleCategory(category)
                    }
                }
            }

            if let _ = result, !vm.scanState.isActive {
                let selectedSize = vm.selectedSizeInCategory(category)
                let selectedCount = vm.selectedCountInCategory(category)
                if selectedSize > 0 {
                    GradientActionButton(
                        title: "Clean \(selectedCount) items (\(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)))",
                        icon: "trash.fill",
                        gradient: AppGradients.accent
                    ) {
                        withAnimation(.pmSpring) {
                            vm.cleanCategory(category)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    @EnvironmentObject var vm: AppViewModel
    let item: CleanableItem
    let color: Color

    @State private var isHovering = false

    var isSelected: Bool {
        vm.isItemSelected(item)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: { vm.toggleItem(item) }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? color : Color.pmTextMuted, lineWidth: 1.5)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: 18, height: 18)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            // File icon
            Image(systemName: fileIcon)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? color.opacity(0.7) : .pmTextMuted)
                .frame(width: 20)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.pmBody)
                    .foregroundColor(isSelected ? .pmTextPrimary : .pmTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.path)
                    .font(.system(size: 10))
                    .foregroundColor(.pmTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Date
            if let date = item.lastModified {
                Text(formatDate(date))
                    .font(.system(size: 10))
                    .foregroundColor(.pmTextMuted)
            }

            // Size
            Text(item.formattedSize)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .pmTextPrimary : .pmTextMuted)
                .frame(width: 70, alignment: .trailing)

            // Reveal button on hover
            if isHovering {
                Button(action: revealInFinder) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.pmTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.pmCard : Color.clear)
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }

    private var fileIcon: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "log", "txt": return "doc.text.fill"
        case "zip", "gz", "tar": return "doc.zipper"
        case "dmg", "iso": return "opticaldisc.fill"
        case "app": return "app.fill"
        case "pkg": return "shippingbox.fill"
        default:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                return "folder.fill"
            }
            return "doc.fill"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }
}
