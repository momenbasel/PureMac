import SwiftUI

/// Landing screen modeled after the new prototype:
/// hero gauge + stats + quick actions + suggestion cards.
/// Replaces the old SmartScanView idle/completed states with a richer
/// at-a-glance view, and delegates active-scan progress to inline state UI.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showConfirmation = false
    @State private var fireCleanConfetti = false
    @State private var lastCleanedScanState: Bool = false
    @State private var hoveredSegment: String?
    /// Confetti burst origin as a fraction of the dashboard, derived from the
    /// SuccessMedal's real frame so the burst tracks it across window sizes
    /// and RTL layout instead of a hand-aimed constant.
    @State private var burstOrigin: UnitPoint = UnitPoint(x: 0.25, y: 0.28)
    @State private var dashboardSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dashboardSpace = "dashboard"

    /// Hero cards rise in with a slight settle and dissolve out; under
    /// Reduce Motion both directions collapse to a plain cross-fade.
    private var heroTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity
                    .combined(with: .offset(y: 12))
                    .combined(with: .scale(scale: 0.98, anchor: .top)),
                removal: .opacity
            )
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch appState.scanState {
                    case .idle:
                        hero
                            .transition(heroTransition)
                        stats
                        if appState.diskInfo.totalSpace > 0 {
                            sectionHeader("Storage composition")
                            storageComposition
                        }
                        if !suggestionRows.isEmpty {
                            sectionHeader("Suggested for you")
                            suggestions
                        }
                    case .scanning:
                        scanningHero
                            .transition(heroTransition)
                        if !appState.allResults.isEmpty {
                            sectionHeader("Found so far")
                            liveResults
                        }
                    case .completed:
                        completedHero
                            .transition(heroTransition)
                        if appState.totalJunkSize > 0 {
                            sectionHeader("By category")
                            categoryChartCard
                            resultsList
                        }
                    case .cleaning:
                        cleaningHero
                            .transition(heroTransition)
                    case .cleaned:
                        cleanedHero
                            .transition(heroTransition)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 920, alignment: .leading)
                .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.scanState)
            }

            // Celebratory burst when a clean cycle finishes with something
            // freed. Origin tracks the SuccessMedal's real frame (see
            // burstOrigin) so it explodes from the celebration on any window
            // size / layout direction.
            // allowsHitTesting=false keeps Done clickable through particles.
            ConfettiView(trigger: fireCleanConfetti, mode: .burst(origin: burstOrigin))
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: dashboardSpace)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { dashboardSize = geo.size }
                    .onChange(of: geo.size) { dashboardSize = $0 }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: appState.scanState) { newState in
            // Fire only on the rising edge of .cleaned with freed > 0 so
            // the burst doesn't replay when the user navigates back to the
            // dashboard while .cleaned is still on screen.
            let isCleaned: Bool = {
                if case .cleaned = newState { return true }
                return false
            }()
            if isCleaned && !lastCleanedScanState && appState.totalFreedSpace > 0 {
                if reduceMotion {
                    // Confetti renders nothing under Reduce Motion; no need
                    // to wait for an entrance spring that isn't playing.
                    fireCleanConfetti.toggle()
                } else {
                    // Let the hero settle and the counter roll before the
                    // burst so the celebration lands as one beat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        fireCleanConfetti.toggle()
                    }
                }
            }
            lastCleanedScanState = isCleaned
        }
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
        // Below this width the side-by-side ring + storage column overflows the
        // card, so the hero stacks vertically and the ring shrinks.
        let compact = dashboardSize.width > 0 && dashboardSize.width < 660
        let ringSize: CGFloat = compact ? 132 : 176

        return CardSurface(padding: compact ? 20 : 26, elevation: .raised,
                           tint: stress ? Tint.orange : Tint.blue) {
            VStack(spacing: compact ? 18 : 24) {
                AdaptiveStack(compact: compact, spacing: compact ? 18 : 30) {
                    ZStack {
                        // Slow atmospheric drift behind the ring — barely-there
                        // ambient depth, frozen under Reduce Motion.
                        HeroDrift(tint: stress ? Tint.orange : Tint.blue)
                        HealthRing(percent: percentUsed)
                            .frame(width: ringSize, height: ringSize)
                        // Small satellite bubbles orbiting the ring — the
                        // playful counterweight to the matte stat cards.
                        OrbSatellites(tint: stress ? Tint.orange : Tint.blue, ringSize: ringSize)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text("Storage")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.8)
                                    if stress {
                                        StatusChip(label: String(localized: "Low space"),
                                                   systemImage: "exclamationmark.triangle.fill",
                                                   tint: Tint.orange)
                                    }
                                }
                                CountUpBytes(bytes: free)
                                    .font(.system(size: 38, weight: .bold))
                                    .foregroundStyle(stress ? Tint.orange : Color.primary)
                                Text(freeOfText(total: total))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                appState.startSmartScan()
                            } label: {
                                Label("Smart Scan", systemImage: "sparkles")
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(GlowProminentButtonStyle(breathes: true, large: true))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                storageMeter(used: used, total: total)
            }
        }
    }

    private func freeOfText(total: Int64) -> String {
        String(
            format: String(localized: "free of %@"),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    /// Full-width segmented meter (Used / Junk / Purgeable / Free) with a
    /// hoverable legend. The same segment math as the composition donut, so
    /// both surfaces always agree.
    private func storageMeter(used: Int64, total: Int64) -> some View {
        let purge = max(0, appState.diskInfo.purgeableSpace)
        let junk = max(0, min(appState.totalJunkSize, used))
        let usedCore = max(0, used - junk - purge)
        let free = max(0, appState.diskInfo.freeSpace)

        var segments: [StackedMeter.Segment] = [
            .init(id: "used", value: Double(usedCore), color: Tint.blue)
        ]
        if junk > 0 {
            segments.append(.init(id: "junk", value: Double(junk), color: Tint.orange))
        }
        if purge > 0 {
            segments.append(.init(id: "purgeable", value: Double(purge), color: Tint.green))
        }
        segments.append(.init(id: "free", value: Double(free), color: Color.primary.opacity(0.10)))

        let usedPct = total > 0 ? Double(used) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 10) {
            StackedMeter(segments: segments, highlightedID: hoveredSegment)

            HStack(spacing: 18) {
                HoverableLegendChip(color: Tint.blue, label: "Used",
                                    value: formatted(usedCore),
                                    percent: shareString(usedCore, of: total)) { hovering in
                    hoveredSegment = hovering ? "used" : nil
                }
                if junk > 0 {
                    HoverableLegendChip(color: Tint.orange, label: "Junk",
                                        value: formatted(junk),
                                        percent: shareString(junk, of: total)) { hovering in
                        hoveredSegment = hovering ? "junk" : nil
                    }
                }
                if purge > 0 {
                    HoverableLegendChip(color: Tint.green, label: "Purgeable",
                                        value: formatted(purge),
                                        percent: shareString(purge, of: total)) { hovering in
                        hoveredSegment = hovering ? "purgeable" : nil
                    }
                }
                Spacer()
                Text(percentUsedText(usedPct))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func shareString(_ part: Int64, of total: Int64) -> String? {
        guard total > 0, part > 0 else { return nil }
        let share = Int((Double(part) / Double(total) * 100).rounded())
        // A rounded 0% is noise — hide it for slivers like APFS purgeable.
        guard share > 0 else { return nil }
        return "\(share)%"
    }

    private func percentUsedText(_ usedPct: Double) -> String {
        String(format: String(localized: "%lld%% used"), Int64(usedPct * 100))
    }

    // MARK: - Stats

    private var stats: some View {
        let free = appState.diskInfo.freeSpace
        let total = appState.diskInfo.totalSpace
        let percentUsed = total > 0 ? Double(total - free) / Double(total) : 0

        // Four across when there's room, two when the dashboard is narrow so the
        // cards don't crush their values.
        let columnCount = dashboardSize.width > 0 && dashboardSize.width < 660 ? 2 : 4
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
            StatCard(
                icon: "internaldrive.fill",
                tint: Tint.blue,
                label: "Free Space",
                value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                delta: total > 0 ? freeSpaceDelta(total: total, percentUsed: percentUsed) : nil,
                byteValue: free
            )
            .staggered(0)
            StatCard(
                icon: "trash.circle.fill",
                tint: Tint.orange,
                label: "Junk Found",
                value: appState.totalJunkSize > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
                    : "—",
                delta: appState.allResults.isEmpty
                    ? String(localized: "Run a scan")
                    : junkFoundDelta(count: appState.allResults.count),
                byteValue: appState.totalJunkSize > 0 ? appState.totalJunkSize : nil
            )
            .staggered(1)
            StatCard(
                icon: "square.grid.2x2.fill",
                tint: Tint.purple,
                label: "Apps",
                value: "\(appState.installedApps.count)",
                delta: String(localized: "installed")
            )
            .staggered(2)
            StatCard(
                icon: "memorychip.fill",
                tint: Tint.green,
                label: "Purgeable",
                value: appState.diskInfo.purgeableSpace > 0
                    ? ByteCountFormatter.string(fromByteCount: appState.diskInfo.purgeableSpace, countStyle: .file)
                    : "—",
                delta: String(localized: "Managed by macOS"),
                byteValue: appState.diskInfo.purgeableSpace > 0 ? appState.diskInfo.purgeableSpace : nil
            )
            .staggered(3)
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

    // MARK: - Storage composition

    private var storageComposition: some View {
        let total = appState.diskInfo.totalSpace
        let free = appState.diskInfo.freeSpace
        let purge = max(0, appState.diskInfo.purgeableSpace)
        let junk = max(0, min(appState.totalJunkSize, appState.diskInfo.usedSpace))
        // "Used" excludes the junk + purgeable slices so the four segments sum
        // to the whole disk without double-counting.
        let usedCore = max(0, appState.diskInfo.usedSpace - junk - purge)

        var segments: [StorageDonut.Segment] = []
        func add(_ id: String, _ value: Int64, _ color: Color, _ label: LocalizedStringKey) {
            guard value > 0 else { return }
            segments.append(.init(
                id: id,
                value: Double(value),
                color: color,
                label: label,
                display: ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
            ))
        }
        add("used", usedCore, Tint.blue, "Used")
        add("junk", junk, Tint.orange, "Junk")
        add("purgeable", purge, Tint.green, "Purgeable")
        add("free", free, Color.primary.opacity(0.14), "Free")

        return CardSurface(padding: 20, elevation: .standard) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    StorageDonut(segments: segments, highlightedID: hoveredSegment)
                        .frame(width: 148, height: 148)
                    VStack(spacing: 1) {
                        Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            .font(.system(size: 18, weight: .bold))
                            .monospacedDigit()
                        Text("total")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                        HoverableLegendChip(
                            color: seg.color, label: seg.label, value: seg.display,
                            percent: shareString(Int64(seg.value), of: total)
                        ) { hovering in
                            hoveredSegment = hovering ? seg.id : nil
                        }
                        .staggered(idx)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Suggestions

    private var suggestions: some View {
        VStack(spacing: 10) {
            ForEach(Array(suggestionRows.enumerated()), id: \.offset) { idx, row in
                SuggestionRow(suggestion: row)
                    .staggered(idx)
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
        CardSurface(padding: 26, elevation: .raised, material: .ultraThinMaterial, tint: Tint.blue) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.scanProgress)
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        sparklesIcon
                        Text("Scanning your Mac")
                            .font(.system(size: 22, weight: .bold))
                    }

                    // Category line slides up as the scan advances.
                    Text(currentlyInText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .id(appState.currentScanCategory)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                )
                        )

                    ShimmerProgressBar(progress: appState.scanProgress)
                        .frame(maxWidth: 320)
                        .padding(.top, 2)

                    // Live file-path ticker — the "it's really working"
                    // signal. Observes the standalone ScanProgressTicker so the
                    // ~10Hz path churn re-renders only this label, not the whole
                    // dashboard (issues #119, #120).
                    ScanPathTicker(ticker: appState.scanTicker)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: appState.currentScanCategory)
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
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    if result.id != appState.allResults.prefix(8).last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                       value: appState.allResults.count)
        }
    }

    // MARK: - Completed state

    private var completedHero: some View {
        let isClean = appState.totalJunkSize <= 0
        return CardSurface(padding: 26, elevation: .raised,
                           tint: isClean ? Tint.green : Tint.orange) {
            HStack(spacing: 24) {
                if isClean {
                    HStack(spacing: 12) {
                        cleanSealIcon
                        Text("Your Mac is clean")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Tint.green)
                    }
                    Spacer()
                    Button("Scan Again") { appState.startSmartScan() }
                        .controlSize(.large)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Junk Found")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tint.orange)
                            .textCase(.uppercase)
                            .tracking(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            CountUpBytes(bytes: appState.totalJunkSize)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Tint.orange, Tint.red],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                            Text("found")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        Text(junkFoundDelta(count: appState.allResults.count))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            if appState.totalSelectedSize > 0 {
                                Button {
                                    showConfirmation = true
                                } label: {
                                    Label {
                                        Text(cleanSelectedLabel)
                                    } icon: {
                                        Image(systemName: "sparkles")
                                    }
                                    .padding(.horizontal, 6)
                                }
                                .buttonStyle(GlowProminentButtonStyle(large: true))
                            }
                            Button("Scan Again") { appState.startSmartScan() }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
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

    private var categoryChartCard: some View {
        let bars = appState.allResults
            .filter { $0.totalSize > 0 }
            .sorted { $0.totalSize > $1.totalSize }
            .prefix(8)
            .map { CategoryBarChart.Bar(category: $0.category, size: $0.totalSize) }

        return CardSurface(padding: 18, elevation: .standard) {
            CategoryBarChart(bars: Array(bars))
        }
    }

    private var resultsList: some View {
        CardSurface(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(appState.allResults.enumerated()), id: \.element.id) { idx, result in
                    CategoryToggleRow(result: result)
                        .staggered(idx)
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
        CardSurface(padding: 26, elevation: .raised, material: .ultraThinMaterial, tint: Tint.orange) {
            HStack(alignment: .center, spacing: 28) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.orange, label: "CLEANING")
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleaning…")
                        .font(.system(size: 22, weight: .bold))
                    Text(percentCompleteText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    ShimmerProgressBar(progress: appState.cleanProgress, tint: Tint.orange)
                        .frame(maxWidth: 320)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var percentCompleteText: String {
        String(format: String(localized: "%lld%% complete"), Int64(appState.cleanProgress * 100))
    }

    /// Convert the medal's frame (in dashboard coordinates) into a UnitPoint
    /// for the confetti emitter. Falls back to the existing value until the
    /// dashboard size is known.
    private func updateBurstOrigin(medalFrame: CGRect) {
        guard dashboardSize.width > 0, dashboardSize.height > 0 else { return }
        burstOrigin = UnitPoint(
            x: max(0, min(1, medalFrame.midX / dashboardSize.width)),
            y: max(0, min(1, medalFrame.midY / dashboardSize.height))
        )
    }

    private var cleanedHero: some View {
        CardSurface(padding: 26, elevation: .raised, material: .ultraThinMaterial, tint: Tint.green) {
            HStack(alignment: .center, spacing: 28) {
                SuccessMedal()
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear { updateBurstOrigin(medalFrame: geo.frame(in: .named(dashboardSpace))) }
                        }
                    )

                VStack(alignment: .leading, spacing: 6) {
                    CountUpBytes(bytes: appState.totalFreedSpace)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Tint.green)
                    Text("freed")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Button("Done") { appState.scanState = .idle }
                        .buttonStyle(GlowProminentButtonStyle(tint: Tint.green, gradient: TintGradient.of(Tint.green)))
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        SectionHeader(text)
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
    /// When set, the headline renders as a rolling byte counter instead of
    /// the static `value` string.
    var byteValue: Int64? = nil

    var body: some View {
        CardSurface(padding: 16, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconTile(systemName: icon, tint: tint, size: 28, glow: true)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer(minLength: 0)
                }
                Group {
                    if let byteValue {
                        CountUpBytes(bytes: byteValue)
                    } else {
                        Text(value)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .font(.system(size: 23, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                if let delta {
                    Text(delta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .pressable(hoverScale: 1.02, lift: true)
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
        CardSurface(padding: 14, tint: suggestion.tint) {
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
        .pressable(hoverScale: 1.01, lift: true)
    }
}

/// Live file-path ticker. Observes the standalone `ScanProgressTicker` directly
/// so the scan engine's ~10Hz path updates re-render only this one label rather
/// than the whole AppState-observing view tree (issues #119, #120).
private struct ScanPathTicker: View {
    @ObservedObject var ticker: ScanProgressTicker

    private var display: String {
        guard !ticker.path.isEmpty else { return "" }
        return (ticker.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Text(display)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 360, alignment: .leading)
            .frame(height: 14)
            .opacity(display.isEmpty ? 0 : 1)
    }
}

// MARK: - Gauges

// ScanningGauge now lives in Components/DashboardCharts.swift (radar sweep +
// halo rings + Reduce Motion compliance).

/// Legend chip wrapper that reports hover for donut/meter cross-highlighting
/// and scales slightly while hovered.
private struct HoverableLegendChip: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String
    var percent: String? = nil
    let onHoverChange: (Bool) -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LegendChip(color: color, label: label, value: value, percent: percent)
            .scaleEffect(hovering && !reduceMotion ? 1.05 : 1, anchor: .leading)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .onHover { h in
                hovering = h
                onHoverChange(h)
            }
    }
}

/// Barely-there radial wash that drifts behind the idle hero ring. Static at
/// rest size under Reduce Motion.
private struct HeroDrift: View {
    let tint: Color

    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RadialGradient(
            colors: [tint.opacity(0.16), .clear],
            center: .center, startRadius: 10, endRadius: 130
        )
        .blur(radius: 24)
        .scaleEffect(drift ? 1.12 : 0.96)
        .offset(x: drift ? 8 : -8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

/// Two small glass bubbles hovering just outside the hero ring. They bob on
/// offset rhythms so the composition feels alive without competing with the
/// gauge itself. Positions are static under Reduce Motion.
private struct OrbSatellites: View {
    let tint: Color
    let ringSize: CGFloat

    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let orbit = ringSize / 2 + 14
        ZStack {
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: 13, height: 13)
                .blur(radius: 0.5)
                .offset(x: -orbit - 6, y: -orbit * 0.55 + (bob ? -7 : 7))
                .opacity(bob ? 0.9 : 0.55)
            Circle()
                .stroke(tint.opacity(0.30), lineWidth: 1)
                .frame(width: 17, height: 17)
                .offset(x: orbit + 4, y: orbit * 0.5 + (bob ? 6 : -6))
            Circle()
                .fill(Tint.purple.opacity(0.18))
                .frame(width: 8, height: 8)
                .offset(x: orbit * 0.35, y: -orbit - 8 + (bob ? -5 : 5))
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}

/// Gradient progress capsule with a traveling shimmer band, replacing the
/// stock linear ProgressView during scans/cleans. Shimmer is masked to the
/// filled portion and removed entirely under Reduce Motion.
private struct ShimmerProgressBar: View {
    let progress: Double
    var tint: Color = Tint.blue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        GeometryReader { geo in
            let fillWidth = geo.size.width * CGFloat(clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(
                        LinearGradient(colors: [tint, tint.opacity(0.7)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(8, fillWidth))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: clamped)

                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let cycle = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                        let bandWidth: CGFloat = 56
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.35), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: CGFloat(cycle) * (geo.size.width + bandWidth) - bandWidth)
                    }
                    .mask(
                        Capsule()
                            .frame(width: max(8, fillWidth))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            }
        }
        .frame(height: 9)
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
                IconTile(systemName: result.category.icon, tint: result.category.color, size: 28, vivid: true)
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

/// Lays its content out horizontally at full width and vertically when the
/// container is too narrow for the row to fit, so wide hero rows reflow into a
/// stacked layout instead of overflowing.
struct AdaptiveStack<Content: View>: View {
    let compact: Bool
    var spacing: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .center, spacing: spacing) { content }
        }
    }
}
