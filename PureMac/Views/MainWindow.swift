import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        .frame(minWidth: 860, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
        }
    }

    // All sidebar items as a flat array so ForEach gives proper selectability.
    // Smart Scan is pinned to the top so users always have a path back to it -
    // otherwise the landing page disappears after selecting another tab (#69).
    private var allSidebarItems: [SidebarItem] {
        let smartSize = appState.categoryResults[.smartScan]?.totalSize ?? appState.totalJunkSize
        let smartBadge = smartSize > 0 ? ByteCountFormatter.string(fromByteCount: smartSize, countStyle: .file) : nil
        var items: [SidebarItem] = [
            SidebarItem(section: .cleaning(.smartScan), label: LocalizedStringKey(CleaningCategory.smartScan.rawValue), icon: CleaningCategory.smartScan.icon, badge: smartBadge, group: .home),
            SidebarItem(section: .apps, label: "Installed Apps", icon: "square.grid.2x2", badge: "\(appState.installedApps.count)", group: .applications),
            SidebarItem(section: .orphans, label: "Orphaned Files", icon: "doc.questionmark", badge: appState.orphanedFiles.count > 0 ? "\(appState.orphanedFiles.count)" : nil, group: .applications),
        ]
        for category in CleaningCategory.scannable {
            let size = appState.categoryResults[category]?.totalSize ?? 0
            let badge = size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : nil
            items.append(SidebarItem(section: .cleaning(category), label: LocalizedStringKey(category.rawValue), icon: category.icon, badge: badge, group: .cleaning))
        }
        return items
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            let grouped = Dictionary(grouping: allSidebarItems, by: \.group)
            ForEach(SidebarGroup.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(grouped[group] ?? [], id: \.section) { item in
                        HStack {
                            Label(item.label, systemImage: item.icon)
                            Spacer()
                            if let badge = item.badge {
                                Text(badge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(item.section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PureMac")
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .apps:
            AppListView()
        case .orphans:
            OrphanListView()
        case .cleaning(let category):
            if category == .smartScan {
                SmartScanView()
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView("PureMac", systemImage: "sparkles", description: "Select a category from the sidebar to get started.")
        }
    }
}

private enum SidebarGroup: Hashable, CaseIterable {
    case home, applications, cleaning

    var title: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .applications: return "Applications"
        case .cleaning: return "Cleaning"
        }
    }
}

private struct SidebarItem {
    let section: AppSection
    let label: LocalizedStringKey
    let icon: String
    let badge: String?
    let group: SidebarGroup
}
