import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: InstalledApp.ID?

    private var filteredApps: [InstalledApp] {
        if searchText.isEmpty {
            return appState.installedApps
        }
        let query = searchText.lowercased()
        return appState.installedApps.filter {
            $0.appName.lowercased().contains(query) ||
            $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView("Loading installed apps...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                Table(filteredApps, selection: $selection) {
                    TableColumn("Application") { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.appName)
                        }
                    }
                    .width(min: 200)

                    TableColumn("Size") { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 80)

                    TableColumn("Bundle Identifier") { app in
                        Text(app.bundleIdentifier)
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .width(min: 180)
                }
                .onChange(of: selection) { newValue in
                    if let id = newValue,
                       let app = appState.installedApps.first(where: { $0.id == id }) {
                        appState.selectedApp = app
                        appState.scanForAppFiles(app)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle("Installed Apps (\(appState.installedApps.count))")
        .toolbar {
            ToolbarItem {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
