import SwiftUI

/// Landing screen modeled after the new prototype:
/// hero gauge + stats + quick actions + suggestion cards.
/// Replaces the old SmartScanView idle/completed states with a richer
/// at-a-glance view, and delegates active-scan progress to inline state UI.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch appState.scanState {
                case .idle:
                    hero
                    stats
                    if !suggestionRows.isEmpty {
                        sectionHeader("Suggested for you")
                        suggestions
                    }
                case .scanning:
                    scanningHero
                    if !appState.allResults.isEmpty {
                        sectionHeader("Found so far")
                        liveResults
                    }
                case .completed:
                    completedHero
                    if appState.totalJunkSize > 0 {
                        sectionHeader("By category")
                        resultsList
                    }
                case .cleaning:
                    cleaningHero
                case .cleaned:
                    cleanedHero
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Clean \(ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file))?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean", role: .destructive) { appState.cleanAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected files. This cannot be undone.")
        }
    }

    // MARK: - Hero (idle)

    private var hero: some View {
        let total = appState.diskInfo.totalSpace
        let used = appState.diskInfo.usedSpace
        let free = appState.diskInfo.freeSpace
        let percentUsed = total > 0 ? Double(used) / Double(total) : 0

        return CardSurface(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                StorageGauge(percentUsed: percentUsed)
                    .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Storage")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                                .font(.system(size: 30, weight: .bold))
                                .monospacedDigit()
                            Text("free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.startSmartScan()
                        } label: {
                            Label("Smart Scan", systemImage: "sparkles")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    storageBreakdown(used: used, total: total)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func storageBreakdown(used: Int64, total: Int64) -> some View {
        let usedPct  = total > 0 ? Double(used) / Double(total) : 0
        let purgePct = total > 0 ? Double(appState.diskInfo.purgeableSpace) / Double(total) : 0
        let junkPct  = total > 0 ? min(0.4, Double(appState.totalJunkSize) / Double(total)) : 0

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(LinearGradient(colors: [Tint.blue, Tint.purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(usedPct))
                    }
                    if junkPct > 0 {
                        Capsule()
                            .fill(Tint.orange)
                            .frame(width: max(8, geo.size.width * CGFloat(junkPct)))
                            .offset(x: geo.size.width * CGFloat(usedPct - junkPct))
                            .opacity(0.85)
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                LegendDot(color: Tint.blue, label: "Used", value: ByteCountFormatter.string(fromByteCount: used, countStyle: .file))
                if appState.totalJunkSize > 0 {
                    LegendDot(color: Tint.orange, label: "Junk",
                              value: ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file))
                }
                if appState.diskInfo.purgeableSpace > 0 {
                    LegendDot(color: Tint.green, label: "Purgeable",
                              value: ByteCountFormatter.string(fromByteCount: appState.diskInfo.purgeableSpace, countStyle: .file))
                }
                Spacer()
                Text("\(Int(usedPct * 100))% used")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Stats

    private var stats: some View {
        let free = appState.diskInfo.freeSpace
        let total = appState.diskInfo.totalSpace
        let percentUsed = total > 0 ? Double(total - free) / Double(total) : 0

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatCard(
                icon: "internaldrive.fill",
                tint: Tint.blue,
                label: "Free Space",
                value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                delta: total > 0 ? "of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(Int(percentUsed * 100))% used" : nil
            )
            StatCard(
                icon: "trash.circle.fill",
                tint: Tint.orange,
                label: "Junk Found",
                value: appState.totalJunkSize > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
                    : "—",
                delta: appState.allResults.isEmpty ? "Run a scan" : "across \(appState.allResults.count) categories"
            )
            StatCard(
                icon: "square.grid.2x2.fill",
                tint: Tint.purple,
                label: "Apps",
                value: "\(appState.installedApps.count)",
                delta: "installed"
            )
            StatCard(
                icon: "memorychip.fill",
                tint: Tint.green,
                label: "Purgeable",
                value: appState.diskInfo.purgeableSpace > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.diskInfo.purgeableSpace, countStyle: .file)
                    : "—",
                delta: "APFS reclaimable"
            )
        }
    }

    // MARK: - Suggestions

    private var suggestions: some View {
        VStack(spacing: 10) {
            ForEach(suggestionRows) { row in
                SuggestionRow(suggestion: row)
            }
        }
    }

    private var suggestionRows: [Suggestion] {
        var out: [Suggestion] = []
        // Surface the largest pending category as a contextual nudge.
        if let biggest = appState.allResults.max(by: { $0.totalSize < $1.totalSize }), biggest.totalSize > 0 {
            out.append(Suggestion(
                icon: biggest.category.icon,
                tint: biggest.category.color,
                title: "\(biggest.category.rawValue) is using \(biggest.formattedSize)",
                subtitle: biggest.category.description,
                pill: biggest.formattedSize
            ))
        }
        if !appState.hasFullDiskAccess {
            out.append(Suggestion(
                icon: "lock.shield.fill",
                tint: Tint.orange,
                title: "Grant Full Disk Access for full results",
                subtitle: "Without it, most caches and uninstall flows fail.",
                pill: "Action"
            ))
        }
        return out
    }

    // MARK: - Scanning state

    private var scanningHero: some View {
        CardSurface(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.scanProgress)
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scanning your Mac")
                        .font(.system(size: 22, weight: .bold))
                    Text("Currently in: \(appState.currentScanCategory)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    ProgressView(value: appState.scanProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var liveResults: some View {
        CardSurface(padding: 0) {
            VStack(spacing: 0) {
                ForEach(appState.allResults.prefix(8)) { result in
                    HStack(spacing: 12) {
                        IconTile(systemName: result.category.icon, tint: result.category.color, size: 26)
                        Text(result.category.rawValue)
                            .font(.system(size: 13))
                        Spacer()
                        Text(result.formattedSize)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if result.id != appState.allResults.prefix(8).last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
    }

    // MARK: - Completed state

    private var completedHero: some View {
        CardSurface(padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if appState.totalJunkSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file))
                            .font(.system(size: 36, weight: .bold))
                            .monospacedDigit()
                        Text("found")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Your Mac is clean", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Tint.green)
                    }
                    Spacer()
                    Button("Scan Again") { appState.startSmartScan() }
                        .controlSize(.large)
                }
                if appState.totalJunkSize > 0 {
                    HStack {
                        if appState.totalSelectedSize > 0 {
                            Button {
                                showConfirmation = true
                            } label: {
                                Label(
                                    "Clean \(ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file))",
                                    systemImage: "sparkles"
                                )
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var resultsList: some View {
        CardSurface(padding: 0) {
            VStack(spacing: 0) {
                ForEach(appState.allResults) { result in
                    CategoryToggleRow(result: result)
                    if result.id != appState.allResults.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
    }

    private var cleaningHero: some View {
        CardSurface(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.orange)
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleaning…")
                        .font(.system(size: 22, weight: .bold))
                    Text("\(Int(appState.cleanProgress * 100))% complete")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var cleanedHero: some View {
        CardSurface(padding: 24) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    Circle().fill(Tint.green.opacity(0.18))
                    Image(systemName: "checkmark")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(Tint.green)
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: appState.totalFreedSpace, countStyle: .file))
                        .font(.system(size: 36, weight: .bold))
                        .monospacedDigit()
                    Text("freed")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Button("Done") { appState.scanState = .idle }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .padding(.top, 4)
    }
}

// MARK: - Components

private struct StatCard: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    let delta: String?

    var body: some View {
        CardSurface(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    IconTile(systemName: icon, tint: tint, size: 26)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta {
                    Text(delta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct Suggestion: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let pill: String?
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    var body: some View {
        CardSurface(padding: 14) {
            HStack(spacing: 14) {
                IconTile(systemName: suggestion.icon, tint: suggestion.tint, size: 36, corner: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let pill = suggestion.pill {
                    Text(pill)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(suggestion.tint.opacity(0.15))
                        )
                        .foregroundStyle(suggestion.tint)
                }
            }
        }
    }
}

// MARK: - Gauges

private struct StorageGauge: View {
    let percentUsed: Double  // 0...1

    var body: some View {
        let pct = max(0, min(1, percentUsed))
        let displayPercent = Int(round(pct * 100))
        let stress = pct > 0.85
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(pct))
                .stroke(
                    AngularGradient(
                        colors: stress
                            ? [Tint.orange, Tint.red]
                            : [Tint.blue, Tint.purple],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: (stress ? Tint.orange : Tint.blue).opacity(0.35), radius: 8, y: 2)
                .animation(.easeOut(duration: 0.8), value: pct)
            VStack(spacing: 2) {
                Text("\(displayPercent)%")
                    .font(.system(size: 44, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("USED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}

private struct ScanningGauge: View {
    let progress: Double
    var tint: Color = Tint.blue
    @State private var rotate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.05, min(0.95, progress))))
                .stroke(
                    AngularGradient(colors: [tint, Tint.green], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 4).repeatForever(autoreverses: false), value: rotate)
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 36, weight: .bold))
                    .monospacedDigit()
                Text("SCANNING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { rotate = true }
    }
}

// MARK: - Toggle row

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
            HStack(spacing: 12) {
                IconTile(systemName: result.category.icon, tint: result.category.color, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(result.category.rawValue))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("\(result.itemCount) items")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.formattedSize)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
