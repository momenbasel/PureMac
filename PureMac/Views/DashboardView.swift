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
            cleanConfirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean", role: .destructive) { appState.cleanAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected files. This cannot be undone.")
        }
    }

    private var cleanConfirmationTitle: String {
        String(
            format: String(localized: "Clean %@?"),
            ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file)
        )
    }

    // MARK: - Hero (idle)

    private var hero: some View {
        let total = appState.diskInfo.totalSpace
        let used = appState.diskInfo.usedSpace
        let free = appState.diskInfo.freeSpace
        let percentUsed = total > 0 ? Double(used) / Double(total) : 0
        let stress = percentUsed > 0.85

        return CardSurface(padding: 24, accent: stress ? Tint.orange : Tint.blue, elevation: .raised) {
            HStack(alignment: .center, spacing: 28) {
                StorageGauge(percentUsed: percentUsed)
                    .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Storage")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                if stress {
                                    StatusChip(label: String(localized: "Low space"),
                                               systemImage: "exclamationmark.triangle.fill",
                                               tint: Tint.orange)
                                }
                            }
                            Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                                .font(.system(size: 34, weight: .bold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: stress
                                            ? [Tint.orange, Tint.red]
                                            : [Color.primary, Color.primary.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                            Text(freeOfText(total: total))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.startSmartScan()
                        } label: {
                            Label("Smart Scan", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    storageBreakdown(used: used, total: total)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func freeOfText(total: Int64) -> String {
        String(
            format: String(localized: "free of %@"),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    private func storageBreakdown(used: Int64, total: Int64) -> some View {
        let usedPct  = total > 0 ? Double(used) / Double(total) : 0
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
                Text(percentUsedText(usedPct))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func percentUsedText(_ usedPct: Double) -> String {
        String(format: String(localized: "%lld%% used"), Int64(usedPct * 100))
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
                delta: total > 0 ? freeSpaceDelta(total: total, percentUsed: percentUsed) : nil
            )
            StatCard(
                icon: "trash.circle.fill",
                tint: Tint.orange,
                label: "Junk Found",
                value: appState.totalJunkSize > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
                    : "—",
                delta: appState.allResults.isEmpty
                    ? String(localized: "Run a scan")
                    : junkFoundDelta(count: appState.allResults.count)
            )
            StatCard(
                icon: "square.grid.2x2.fill",
                tint: Tint.purple,
                label: "Apps",
                value: "\(appState.installedApps.count)",
                delta: String(localized: "installed")
            )
            StatCard(
                icon: "memorychip.fill",
                tint: Tint.green,
                label: "Purgeable",
                value: appState.diskInfo.purgeableSpace > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.diskInfo.purgeableSpace, countStyle: .file)
                    : "—",
                delta: String(localized: "APFS reclaimable")
            )
        }
    }

    private func freeSpaceDelta(total: Int64, percentUsed: Double) -> String {
        String(
            format: String(localized: "of %@ · %lld%% used"),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file),
            Int64(percentUsed * 100)
        )
    }

    private func junkFoundDelta(count: Int) -> String {
        String(format: String(localized: "across %lld categories"), Int64(count))
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
            let title = String(
                format: String(localized: "%@ is using %@"),
                String(localized: String.LocalizationValue(biggest.category.rawValue)),
                biggest.formattedSize
            )
            out.append(Suggestion(
                icon: biggest.category.icon,
                tint: biggest.category.color,
                title: title,
                subtitle: String(localized: String.LocalizationValue(biggest.category.description)),
                pill: biggest.formattedSize
            ))
        }
        if !appState.hasFullDiskAccess {
            out.append(Suggestion(
                icon: "lock.shield.fill",
                tint: Tint.orange,
                title: String(localized: "Grant Full Disk Access for full results"),
                subtitle: String(localized: "Without it, most caches and uninstall flows fail."),
                pill: String(localized: "Action")
            ))
        }
        return out
    }

    // MARK: - Scanning state

    private var scanningHero: some View {
        CardSurface(padding: 24, accent: Tint.blue, elevation: .raised) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.scanProgress)
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        sparklesIcon
                        Text("Scanning your Mac")
                            .font(.system(size: 22, weight: .bold))
                    }
                    Text(currentlyInText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    ProgressView(value: appState.scanProgress)
                        .progressViewStyle(.linear)
                        .tint(Tint.blue)
                        .frame(maxWidth: 320)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var currentlyInText: String {
        String(
            format: String(localized: "Currently in: %@"),
            String(localized: String.LocalizationValue(appState.currentScanCategory))
        )
    }

    private var liveResults: some View {
        CardSurface(padding: 0) {
            VStack(spacing: 0) {
                ForEach(appState.allResults.prefix(8)) { result in
                    HStack(spacing: 12) {
                        IconTile(systemName: result.category.icon, tint: result.category.color, size: 26)
                        Text(LocalizedStringKey(result.category.rawValue))
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
        let isClean = appState.totalJunkSize <= 0
        return CardSurface(padding: 24, accent: isClean ? Tint.green : Tint.orange, elevation: .raised) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if !isClean {
                        Text(ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file))
                            .font(.system(size: 40, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(
                                LinearGradient(colors: [Tint.orange, Tint.red],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        Text("found")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            cleanSealIcon
                            Text("Your Mac is clean")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Tint.green)
                        }
                    }
                    Spacer()
                    Button("Scan Again") { appState.startSmartScan() }
                        .controlSize(.large)
                }
                if !isClean {
                    HStack {
                        if appState.totalSelectedSize > 0 {
                            Button {
                                showConfirmation = true
                            } label: {
                                Label {
                                    Text(cleanSelectedLabel)
                                } icon: {
                                    Image(systemName: "sparkles")
                                }
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

    private var cleanSelectedLabel: String {
        String(
            format: String(localized: "Clean %@"),
            ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file)
        )
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

    @ViewBuilder
    private var cleanSealIcon: some View {
        let base = Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Tint.green)
        if #available(macOS 14.0, *) {
            base.symbolEffect(.bounce, value: appState.totalJunkSize)
        } else {
            base
        }
    }

    @ViewBuilder
    private var bigCheckmark: some View {
        let base = Image(systemName: "checkmark")
            .font(.system(size: 60, weight: .bold))
            .foregroundStyle(Tint.green)
            .shadow(color: Tint.green.opacity(0.5), radius: 12)
        if #available(macOS 14.0, *) {
            base.symbolEffect(.bounce, value: appState.totalFreedSpace)
        } else {
            base
        }
    }

    @ViewBuilder
    private var sparklesIcon: some View {
        let base = Image(systemName: "sparkles")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(
                LinearGradient(colors: [Tint.blue, Tint.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        if #available(macOS 14.0, *) {
            base.symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            base
        }
    }

    private var cleaningHero: some View {
        CardSurface(padding: 24, accent: Tint.orange, elevation: .raised) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.orange, label: "CLEANING")
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleaning…")
                        .font(.system(size: 22, weight: .bold))
                    Text(percentCompleteText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var percentCompleteText: String {
        String(format: String(localized: "%lld%% complete"), Int64(appState.cleanProgress * 100))
    }

    private var cleanedHero: some View {
        CardSurface(padding: 24, accent: Tint.green, elevation: .raised) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    Circle()
                        .fill(Tint.green.opacity(0.12))
                        .blur(radius: 20)
                    Circle()
                        .fill(
                            LinearGradient(colors: [Tint.green.opacity(0.30), Tint.green.opacity(0.10)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Circle()
                        .strokeBorder(Tint.green.opacity(0.30), lineWidth: 2)
                    bigCheckmark
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: appState.totalFreedSpace, countStyle: .file))
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(
                            LinearGradient(colors: [Tint.green, Color(red: 0.10, green: 0.65, blue: 0.40)],
                                           startPoint: .top, endPoint: .bottom)
                        )
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

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .padding(.top, 4)
    }
}

// MARK: - Components

private struct StatCard: View {
    let icon: String
    let tint: Color
    let label: LocalizedStringKey
    let value: String
    let delta: String?

    var body: some View {
        CardSurface(padding: 14, accent: tint) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    IconTile(systemName: icon, tint: tint, size: 28, glow: true)
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta {
                    Text(delta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .pressable(hoverScale: 1.018)
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
        CardSurface(padding: 14, accent: suggestion.tint) {
            HStack(spacing: 14) {
                IconTile(systemName: suggestion.icon, tint: suggestion.tint,
                         size: 38, corner: 10, glow: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let pill = suggestion.pill {
                    StatusChip(label: pill, tint: suggestion.tint)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .pressable(hoverScale: 1.01)
    }
}

// MARK: - Gauges

private struct StorageGauge: View {
    let percentUsed: Double  // 0...1
    @State private var glow = false

    var body: some View {
        let pct = max(0, min(1, percentUsed))
        let displayPercent = Int(round(pct * 100))
        let stress = pct > 0.85
        let primaryGradient: [Color] = stress
            ? [Tint.orange, Tint.red]
            : [Tint.blue, Tint.purple]

        ZStack {
            // Soft outer halo to give the ring depth.
            Circle()
                .fill(primaryGradient.first!.opacity(glow ? 0.18 : 0.10))
                .blur(radius: 24)
                .scaleEffect(0.95)

            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: CGFloat(pct))
                .stroke(
                    AngularGradient(colors: primaryGradient + [primaryGradient.first!], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: primaryGradient.first!.opacity(0.45), radius: 10, y: 2)
                .animation(.easeOut(duration: 0.8), value: pct)

            // Pulsing dot at the arc tip — adds life without distracting.
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .overlay(Circle().fill(primaryGradient.last!).frame(width: 4, height: 4))
                .shadow(color: primaryGradient.last!.opacity(0.6), radius: 4)
                .offset(y: -80)
                .rotationEffect(.degrees(360 * pct))
                .opacity(pct > 0.02 ? 1 : 0)
                .animation(.easeOut(duration: 0.8), value: pct)

            VStack(spacing: 2) {
                Text("\(displayPercent)%")
                    .font(.system(size: 46, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(
                        LinearGradient(colors: primaryGradient, startPoint: .top, endPoint: .bottom)
                    )
                Text("USED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: LocalizedStringKey
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
    var label: LocalizedStringKey = "SCANNING"
    @State private var rotate = false
    @State private var shimmer = false

    var body: some View {
        ZStack {
            // Halo
            Circle()
                .fill(tint.opacity(shimmer ? 0.20 : 0.10))
                .blur(radius: 24)
                .scaleEffect(0.95)

            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(max(0.05, min(0.95, progress))))
                .stroke(
                    AngularGradient(colors: [tint, Tint.green, tint], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .shadow(color: tint.opacity(0.45), radius: 10, y: 2)
                .animation(.linear(duration: 4).repeatForever(autoreverses: false), value: rotate)

            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 38, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(
                        LinearGradient(colors: [tint, Tint.green], startPoint: .top, endPoint: .bottom)
                    )
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            rotate = true
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
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
                    Text(itemsCountText)
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

    private var itemsCountText: String {
        String(format: String(localized: "%lld items"), Int64(result.itemCount))
    }
}
