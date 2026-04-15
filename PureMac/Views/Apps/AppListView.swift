import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: InstalledApp.ID?
    @State private var sortOrder: [KeyPathComparator<InstalledApp>] = [
        .init(\.appName, order: .forward)
    ]

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        if searchText.isEmpty {
            base = appState.installedApps
        } else {
            let query = searchText.lowercased()
            base = appState.installedApps.filter {
                $0.appName.lowercased().contains(query) ||
                $0.bundleIdentifier.lowercased().contains(query)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            // Cap the left pane's maxWidth so dragging the splitter cannot
            // push it past half the window and break the layout (#60).
            appTable
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 600)

            fileDetail
                .frame(minWidth: 300)
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle(appListTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if !appState.selectedFiles.isEmpty {
                    Button(uninstallButtonTitle, role: .destructive) {
                        appState.removeSelectedFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    private var appListTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    private var uninstallButtonTitle: String {
        String(format: String(localized: "Uninstall (%lld files)"), Int64(appState.selectedFiles.count))
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
                Table(filteredApps, selection: selectionBinding, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.appName) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.appName)
                        }
                    }
                    .width(min: 150)

                    TableColumn("Size", value: \.size) { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 70)
                }
            }
        }
    }

    private var selectionBinding: Binding<InstalledApp.ID?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if let id = newValue,
                   let app = appState.installedApps.first(where: { $0.id == id }) {
                    appState.selectedApp = app
                    appState.scanForAppFiles(app)
                }
            }
        )
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
