import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
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
        let matches = filteredApps
        let visibleApp = appState.selectedApp.flatMap { selected in
            searchText.isEmpty || matches.contains(where: { $0.id == selected.id }) ? selected : nil
        }
        return HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Text("Installed Apps").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(matches.count.formatted())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
                appTable(matches)
            }
            .frame(minWidth: 250, idealWidth: 320, maxWidth: 520)

            fileDetail(visibleApp)
                .frame(minWidth: 300)
                .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: visibleApp?.id)
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle("Uninstaller")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    appState.reviewSelectedAppFiles(appState.selectedFiles)
                } label: {
                    Label("Review Removal", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("apps.reviewRemoval")
                .disabled(visibleApp == nil || appState.selectedFiles.isEmpty || !appState.canBeginAppRemoval)
            }
        }
    }

    // MARK: - App Table (left side)

    private func appTable(_ matches: [InstalledApp]) -> some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
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
            } else if matches.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No matching apps").font(.headline)
                    Button("Clear search") { searchText = "" }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(matches, selection: selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.appName) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable().frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(app.appName)
                                .accessibilityIdentifier("apps.name.\(app.bundleIdentifier)")
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
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
    }

    private var selection: Binding<InstalledApp.ID?> {
        Binding(get: { appState.selectedApp?.id }, set: { id in
            guard let id, appState.selectedApp?.id != id,
                  let app = appState.installedApps.first(where: { $0.id == id }) else { return }
            appState.selectedApp = app
            appState.scanForAppFiles(app)
        })
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private func fileDetail(_ selected: InstalledApp?) -> some View {
        if let app = selected {
            AppFilesView(app: app)
                .id(app.id)
                .transition(motionEnabled ? .opacity : .identity)
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select an app from the list to see all its related files across your system.",
                tint: Tint.purple
            )
        }
    }
}
