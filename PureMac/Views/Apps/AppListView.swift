import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: AppInfoPlaceholder.ID?

    private var filteredApps: [AppInfoPlaceholder] {
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
            if appState.installedApps.isEmpty {
                EmptyStateView("No Apps Loaded", systemImage: "square.grid.2x2", description: "App scanning is being set up. This feature will discover all installed applications and their related files.")
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

                    TableColumn("Bundle Identifier") { app in
                        Text(app.bundleIdentifier)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .width(min: 180)
                }
                .onChange(of: selection) { newValue in
                    if let id = newValue,
                       let app = appState.installedApps.first(where: { $0.id == id }) {
                        appState.selectedApp = app
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle("Installed Apps (\(appState.installedApps.count))")
    }
}
