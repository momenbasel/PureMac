import SwiftUI

struct SmartScanView: View {
    @EnvironmentObject var appState: AppState
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            switch appState.scanState {
            case .idle:
                idleView
            case .scanning:
                scanningView
            case .completed:
                completedView
            case .cleaning:
                cleaningView
            case .cleaned:
                cleanedView
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Ready to Scan")
                .font(.title2)

            GroupBox("Disk Usage") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Total")
                            .foregroundStyle(.secondary)
                        Text(appState.diskInfo.formattedTotal)
                            .fontWeight(.medium)
                    }
                    GridRow {
                        Text("Used")
                            .foregroundStyle(.secondary)
                        Text(appState.diskInfo.formattedUsed)
                            .fontWeight(.medium)
                    }
                    GridRow {
                        Text("Free")
                            .foregroundStyle(.secondary)
                        Text(appState.diskInfo.formattedFree)
                            .fontWeight(.medium)
                    }
                    if appState.diskInfo.purgeableSpace > 0 {
                        GridRow {
                            Text("Purgeable")
                                .foregroundStyle(.secondary)
                            Text(appState.diskInfo.formattedPurgeable)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: 300)

            Button("Start Scan") {
                appState.startSmartScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 20) {
            Text("Scanning...")
                .font(.title2)

            ProgressView(value: appState.scanProgress) {
                Text(appState.currentScanCategory)
                    .foregroundStyle(.secondary)
            } currentValueLabel: {
                Text("\(Int(appState.scanProgress * 100))%")
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 350)

            if !appState.allResults.isEmpty {
                GroupBox("Results Found") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.allResults.prefix(6)) { result in
                            HStack {
                                Image(systemName: result.category.icon)
                                    .frame(width: 20)
                                Text(LocalizedStringKey(result.category.rawValue))
                                Spacer()
                                Text(result.formattedSize)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 400)
            }
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(spacing: 20) {
            if appState.totalJunkSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file))
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                Text("junk found")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.allResults) { result in
                            CategoryToggleRow(result: result)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 450)

                HStack(spacing: 12) {
                    if appState.totalSelectedSize > 0 {
                        Button("Clean Selected (\(ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file)))") {
                            showConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Button("Scan Again") {
                        appState.startSmartScan()
                    }
                    .controlSize(.large)
                }
                .confirmationDialog("Clean \(ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file))?", isPresented: $showConfirmation, titleVisibility: .visible) {
                    Button("Clean", role: .destructive) {
                        appState.cleanAll()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete the selected files. This cannot be undone.")
                }
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("Your Mac is clean")
                    .font(.title2)

                Button("Scan Again") {
                    appState.startSmartScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Cleaning

    private var cleaningView: some View {
        VStack(spacing: 20) {
            ProgressView(value: appState.cleanProgress) {
                Text("Cleaning...")
                    .font(.title3)
            } currentValueLabel: {
                Text("\(Int(appState.cleanProgress * 100))%")
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 350)
        }
    }

    // MARK: - Cleaned

    private var cleanedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text(ByteCountFormatter.string(fromByteCount: appState.totalFreedSpace, countStyle: .file))
                .font(.system(size: 36, weight: .bold, design: .rounded))

            Text("freed")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button("Done") {
                appState.scanState = .idle
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Category Toggle Row

private struct CategoryToggleRow: View {
    @EnvironmentObject var appState: AppState
    let result: CategoryResult

    private var isFullySelected: Bool {
        appState.selectedCountInCategory(result.category) == result.itemCount
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isFullySelected },
            set: { newValue in
                if newValue {
                    appState.selectAllInCategory(result.category)
                } else {
                    appState.deselectAllInCategory(result.category)
                }
            }
        )) {
            HStack {
                Image(systemName: result.category.icon)
                    .frame(width: 20)
                Text(LocalizedStringKey(result.category.rawValue))
                Spacer()
                Text("\(result.itemCount) items")
                    .foregroundStyle(.secondary)
                Text(result.formattedSize)
                    .fontWeight(.medium)
            }
        }
        .toggleStyle(.checkbox)
    }
}
