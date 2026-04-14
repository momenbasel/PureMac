import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // App branding
            HStack(spacing: 12) {
                Image("SidebarLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text("PureMac")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.pmTextPrimary)

                    Text("System Cleaner")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.pmTextMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 48)
            .padding(.bottom, 24)

            // Smart Scan card
            SmartScanSidebarCard(
                isSelected: vm.selectedCategory == .smartScan,
                totalJunk: vm.totalJunkSize
            )
            .onTapGesture { vm.selectedCategory = .smartScan }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)

            // Category list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    SectionHeader(title: "CLEANING")

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

            // Bottom status
            VStack(spacing: 8) {
                if let lastCleaned = vm.lastCleanedDate {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.pmSuccess)
                            .frame(width: 6, height: 6)

                        Text("Cleaned \(timeAgo(lastCleaned))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.pmTextMuted)
                    }
                }

                Text("v\(AppConstants.appVersion)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.pmTextMuted.opacity(0.6))
            }
            .padding(.bottom, 14)
        }
        .background(
            Color.pmSidebar
                .ignoresSafeArea()
        )
    }

    func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Smart Scan Card

struct SmartScanSidebarCard: View {
    let isSelected: Bool
    let totalJunk: Int64

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.pmAccent)
                    .frame(width: 36, height: 36)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Scan")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)

                if totalJunk > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: totalJunk, countStyle: .file) + " found")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.pmAccentLight)
                } else {
                    Text("Scan everything at once")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.pmTextMuted)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.pmTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.pmAccent.opacity(0.12) : Color.pmCard.opacity(isHovering ? 0.8 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.pmAccent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.pmTextMuted)
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .padding(.top, 2)
    }
}

// MARK: - Sidebar Item

struct SidebarItem: View {
    let category: CleaningCategory
    let isSelected: Bool
    let resultSize: Int64?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Selection indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? category.color : Color.clear)
                .frame(width: 3, height: 20)
                .padding(.trailing, 9)

            // Icon with colored background
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(category.color.opacity(isSelected ? 0.15 : 0.08))
                    .frame(width: 30, height: 30)

                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? category.color : category.color.opacity(0.6))
            }

            // Label
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isSelected ? .pmTextPrimary : .pmTextSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, 10)

            Spacer()

            // Size badge
            if let size = resultSize, size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(isSelected ? category.color : .pmTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(category.color.opacity(isSelected ? 0.12 : 0.06))
                    )
            }
        }
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.pmCard.opacity(0.6) : (isHovering ? Color.pmCard.opacity(0.3) : .clear))
                .padding(.horizontal, 6)
        )
        .onHover { hovering in
            withAnimation(.pmSmooth) { isHovering = hovering }
        }
        .contentShape(Rectangle())
    }
}
