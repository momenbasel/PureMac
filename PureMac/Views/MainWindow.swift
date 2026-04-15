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

    // All sidebar items as a flat array so ForEach gives proper selectability
    private var allSidebarItems: [SidebarItem] {
        var items: [SidebarItem] = [
            SidebarItem(section: .apps, label: "Installed Apps", icon: "square.grid.2x2", badge: "\(appState.installedApps.count)", group: "Applications"),
            SidebarItem(section: .orphans, label: "Orphaned Files", icon: "doc.questionmark", badge: appState.orphanedFiles.count > 0 ? "\(appState.orphanedFiles.count)" : nil, group: "Applications"),
        ]
        for category in CleaningCategory.scannable {
            let size = appState.categoryResults[category]?.totalSize ?? 0
            let badge = size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : nil
            items.append(SidebarItem(section: .cleaning(category), label: category.rawValue, icon: category.icon, badge: badge, group: "Cleaning"))
        }
        return items
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            let grouped = Dictionary(grouping: allSidebarItems, by: \.group)
            let order = ["Applications", "Cleaning"]
            ForEach(order, id: \.self) { group in
                Section {
                    ForEach(grouped[group] ?? [], id: \.section) { item in
                        HStack {
                            Label {
                                Text(LocalizedStringKey(item.label))
                            } icon: {
                                Image(systemName: item.icon)
                            }
                            Spacer()
                            if let badge = item.badge {
                                Text(badge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(item.section)
                    }
                } header: {
                    Text(LocalizedStringKey(group))
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

private struct SidebarItem {
    let section: AppSection
    let label: String
    let icon: String
    let badge: String?
    let group: String
}
