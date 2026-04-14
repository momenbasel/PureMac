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
        HSplitView {
            appTable
                .frame(minWidth: 300, idealWidth: 380)

            fileDetail
                .frame(minWidth: 300)
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle("Installed Apps (\(appState.installedApps.count))")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if !appState.selectedFiles.isEmpty {
                    Button("Uninstall (\(appState.selectedFiles.count) files)", role: .destructive) {
                        appState.removeSelectedFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
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
                    .width(min: 150)

                    TableColumn("Size") { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 70)
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
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private var fileDetail: some View {
        if let app = appState.selectedApp {
            AppFilesView(app: app)
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select an app from the list to see all its related files across your system."
            )
        }
    }
}
