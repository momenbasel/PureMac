import SwiftUI

struct AppUninstallerView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Search bar
            searchBar
                .padding(.horizontal, 32)
                .padding(.bottom, 12)

            Divider()
                .background(Color.pmSeparator)
                .padding(.horizontal, 32)

            // App list
            if vm.isLoadingApps {
                loadingState
            } else if vm.installedApps.isEmpty {
                emptyState
            } else if vm.filteredApps.isEmpty {
                noResultsState
            } else {
                appList
            }

            Spacer()
        }
        .onAppear {
            if vm.installedApps.isEmpty {
                vm.loadInstalledApps()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(CleaningCategory.appUninstaller.color.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: CleaningCategory.appUninstaller.icon)
                    .font(.system(size: 22))
                    .foregroundColor(CleaningCategory.appUninstaller.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("App Uninstaller")
                    .font(.pmHeadline)
                    .foregroundColor(.pmTextPrimary)

                Text("Remove apps and all their associated data")
                    .font(.pmCaption)
                    .foregroundColor(.pmTextSecondary)
            }

            Spacer()

            Button(action: { vm.loadInstalledApps() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(.pmTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.pmCard.opacity(0.6))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Refresh app list")

            if !vm.installedApps.isEmpty {
                Text("\(vm.installedApps.count) apps")
                    .font(.pmCaption)
                    .foregroundColor(.pmTextMuted)
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.pmTextMuted)

            TextField("Search apps...", text: $vm.appSearchText)
                .textFieldStyle(.plain)
                .font(.pmBody)
                .foregroundColor(.pmTextPrimary)

            if !vm.appSearchText.isEmpty {
                Button(action: { vm.appSearchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.pmTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.pmCard)
        .cornerRadius(8)
    }

    // MARK: - App List

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(vm.filteredApps) { app in
                    AppRow(app: app)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Scanning applications...")
                .font(.pmBody)
                .foregroundColor(.pmTextSecondary)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "app.badge.checkmark.fill")
                .font(.system(size: 48))
                .foregroundColor(.pmSuccess)
            Text("No removable apps found")
                .font(.pmSubheadline)
                .foregroundColor(.pmTextSecondary)
            Spacer()
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.pmTextMuted)
            Text("No apps matching \"\(vm.appSearchText)\"")
                .font(.pmBody)
                .foregroundColor(.pmTextSecondary)
            Spacer()
        }
    }
}

// MARK: - App Row

struct AppRow: View {
    @EnvironmentObject var vm: AppViewModel
    let app: InstalledApp

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.pmCard)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "app.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.pmTextMuted)
                        )
                }

                // App info
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.pmBody)
                        .foregroundColor(.pmTextPrimary)
                        .lineLimit(1)

                    Text(app.bundleIdentifier)
                        .font(.system(size: 10))
                        .foregroundColor(.pmTextMuted)
                        .lineLimit(1)
                }

                Spacer()

                // Associated files count
                if !app.associatedFiles.isEmpty {
                    Button(action: {
                        withAnimation(.pmSmooth) { isExpanded.toggle() }
                    }) {
                        HStack(spacing: 4) {
                            Text("\(app.associatedFiles.count) related")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.pmTextMuted)

                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.pmTextMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.pmCard)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Total size
                Text(app.formattedTotalSize)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.pmTextPrimary)
                    .frame(width: 70, alignment: .trailing)

                // Uninstall button
                Button(action: { showConfirmation = true }) {
                    Text("Uninstall")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(CleaningCategory.appUninstaller.color)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Expanded associated files
            if isExpanded && !app.associatedFiles.isEmpty {
                VStack(spacing: 2) {
                    // App bundle itself
                    AssociatedFileRow(
                        name: "\(app.name).app",
                        path: app.path,
                        size: app.formattedAppSize,
                        kind: "Application"
                    )

                    ForEach(app.associatedFiles) { file in
                        AssociatedFileRow(
                            name: file.name,
                            path: file.path,
                            size: file.formattedSize,
                            kind: file.kind.rawValue
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.pmCardHover : Color.pmCard.opacity(0.4))
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
        .alert("Uninstall \(app.name)?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                withAnimation(.pmSpring) {
                    vm.uninstallApp(app)
                }
            }
        } message: {
            Text("This will permanently remove \(app.name) and \(app.associatedFiles.count) associated file\(app.associatedFiles.count == 1 ? "" : "s") (\(app.formattedTotalSize)). This action cannot be undone.")
        }
    }
}

// MARK: - Associated File Row

struct AssociatedFileRow: View {
    let name: String
    let path: String
    let size: String
    let kind: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForKind)
                .font(.system(size: 10))
                .foregroundColor(.pmTextMuted)
                .frame(width: 16)

            Text(kind)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.pmTextMuted)
                .frame(width: 110, alignment: .leading)

            Text(name)
                .font(.system(size: 10))
                .foregroundColor(.pmTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(size)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.pmTextMuted)

            if isHovering {
                Button(action: {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.pmTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.pmCard : Color.clear)
        )
        .onHover { h in
            withAnimation(.pmSmooth) { isHovering = h }
        }
    }

    private var iconForKind: String {
        switch kind {
        case "Preferences": return "slider.horizontal.3"
        case "Application Support": return "folder.fill"
        case "Caches": return "internaldrive.fill"
        case "Saved State": return "clock.fill"
        case "Container": return "shippingbox.fill"
        case "Group Container": return "square.stack.3d.up.fill"
        case "Logs": return "doc.text.fill"
        case "Web Data": return "globe"
        case "Application": return "app.fill"
        default: return "doc.fill"
        }
    }
}
