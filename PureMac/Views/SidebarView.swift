import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // App logo / title
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(AppGradients.primary)
                            .frame(width: 36, height: 36)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text("PureMac")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.pmTextPrimary)

                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 48) // Account for title bar
            .padding(.bottom, 24)

            // Category list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    // Smart Scan - always first
                    SidebarItem(
                        category: .smartScan,
                        isSelected: vm.selectedCategory == .smartScan,
                        resultSize: vm.totalJunkSize
                    )
                    .onTapGesture { vm.selectedCategory = .smartScan }

                    Divider()
                        .background(Color.pmSeparator)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    // Section header
                    HStack {
                        Text("CLEANING")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.pmTextMuted)
                            .tracking(1.2)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)

                    ForEach(CleaningCategory.scannable) { category in
                        SidebarItem(
                            category: category,
                            isSelected: vm.selectedCategory == category,
                            resultSize: vm.categoryResults[category]?.totalSize
                        )
                        .onTapGesture { vm.selectedCategory = category }
                    }
                }
                .padding(.bottom, 16)
            }

            Spacer()

            // Bottom info
            VStack(spacing: 8) {
                Divider()
                    .background(Color.pmSeparator)

                if let lastCleaned = vm.lastCleanedDate {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.pmSuccess)
                        Text("Last cleaned: \(timeAgo(lastCleaned))")
                            .font(.system(size: 10))
                            .foregroundColor(.pmTextMuted)
                    }
                    .padding(.horizontal, 16)
                }

                Text("v\(AppConstants.appVersion)")
                    .font(.system(size: 10))
                    .foregroundColor(.pmTextMuted)
                    .padding(.bottom, 12)
            }
        }
        .background(
            ZStack {
                AppGradients.sidebar
                    .ignoresSafeArea()
                // Subtle right border glow
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.pmAccent.opacity(0.05), .clear],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                        .frame(width: 1)
                }
            }
        )
    }

    func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sidebar Item

struct SidebarItem: View {
    let category: CleaningCategory
    let isSelected: Bool
    let resultSize: Int64?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? category.color.opacity(0.2) : Color.clear)
                    .frame(width: 32, height: 32)

                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? category.color : .pmTextSecondary)
            }

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.pmBody)
                    .foregroundColor(isSelected ? .pmTextPrimary : .pmTextSecondary)
                    .lineLimit(1)

                if let size = resultSize, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(category.color)
                }
            }

            Spacer()

            // Size badge
            if let size = resultSize, size > 0, !isSelected {
                Circle()
                    .fill(category.color.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.pmCard : (isHovering ? Color.pmCard.opacity(0.5) : .clear))
        )
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.pmSmooth) { isHovering = hovering }
        }
        .contentShape(Rectangle())
    }
}
