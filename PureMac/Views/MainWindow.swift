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
        .frame(minWidth: 800, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Applications") {
                Label("Installed Apps", systemImage: "square.grid.2x2")
                    .tag(AppSection.apps)
                Label("Orphaned Files", systemImage: "doc.questionmark")
                    .tag(AppSection.orphans)
            }

            Section("Cleaning") {
                ForEach(CleaningCategory.scannable) { category in
                    HStack {
                        Label(category.rawValue, systemImage: category.icon)
                        Spacer()
                        if let size = appState.categoryResults[category]?.totalSize, size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(AppSection.cleaning(category))
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
            Text("Installed Apps")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .orphans:
            Text("Orphaned Files")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cleaning(let category):
            if category == .smartScan {
                SmartScanView()
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            Text("Select a category")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
