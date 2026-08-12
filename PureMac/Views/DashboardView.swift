import SwiftUI

/// Landing screen modeled after the new prototype:
/// hero gauge + stats + quick actions + suggestion cards.
/// Replaces the old SmartScanView idle/completed states with a richer
/// at-a-glance view, and delegates active-scan progress to inline state UI.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    var onNavigate: (AppSection) -> Void = { _ in }

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
                VStack(alignment: .leading, spacing: 14) {
                    pageHeader

                    switch appState.scanState {
                    case .idle:
                        hero
                            .transition(heroTransition)
                        sectionHeader("Care areas")
                        careOverview
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
                            sectionHeader("Review what was found")
                            findingsGrid
                        }
                    case .cleaning:
                        cleaningHero
                            .transition(heroTransition)
                    case .cleaned:
                        cleanedHero
                            .transition(heroTransition)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: 1220, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
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

    // MARK: - Page chrome

    private var pageHeader: some View {
        let status = headerStatus

        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Smart Care")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.45)
                    .accessibilityAddTraits(.isHeader)
                Text(headerSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            HStack(spacing: 12) {
                StatusChip(
                    label: status.label,
                    systemImage: status.systemImage,
                    tint: status.tint
                )
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(lastCareText(relativeTo: timeline.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var headerSubtitle: String {
        switch appState.scanState {
        case .idle:
            return String(localized: "One scan checks every cleanup tool and prepares a plan for your review.")
        case .scanning:
            return String(localized: "PureMac is checking your Mac without removing anything.")
        case .completed:
            return String(localized: "Choose what to keep, then clean everything in one controlled pass.")
        case .cleaning:
            return String(localized: "Selected items are being removed safely.")
        case .cleaned:
            return String(localized: "Cleanup complete. Your storage summary is refreshing.")
        }
    }

    private var headerStatus: (label: String, systemImage: String, tint: Color) {
        switch appState.scanState {
        case .idle:
            return appState.hasFullDiskAccess
                ? (String(localized: "Ready"), "checkmark.circle.fill", Tint.green)
                : (String(localized: "Limited access"), "lock.fill", Tint.orange)
        case .scanning:
            return (String(localized: "Scanning"), "sparkles", Tint.blue)
        case .completed:
            return appState.totalJunkSize > 0
                ? (String(localized: "Review ready"), "list.bullet.clipboard.fill", Tint.orange)
                : (String(localized: "All clear"), "checkmark.seal.fill", Tint.green)
        case .cleaning:
            return (String(localized: "Cleaning"), "wand.and.stars", Tint.orange)
        case .cleaned:
            return (String(localized: "Complete"), "checkmark.seal.fill", Tint.green)
        }
    }

    private func lastCareText(relativeTo now: Date) -> String {
        guard let date = appState.lastCleanedDate else {
            return String(localized: "No cleanup run yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(format: String(localized: "Last clean: %@"), relative)
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
        let free = appState.diskInfo.freeSpace
        // Use one source of truth for every percentage shown in this hero.
        // APFS can report `usedSpace` and `freeSpace` on slightly different
        // schedules, which previously produced a visible 71%/72% mismatch.
        let used = max(0, total - free)
        let percentUsed = total > 0
            ? max(0, min(1, Double(used) / Double(total)))
            : 0
        let stress = percentUsed >= 0.85
        let compact = dashboardSize.width > 0 && dashboardSize.width < 760
        let coreSize: CGFloat = compact ? 250 : 304

        return SmartCareStageSurface(
            tint: stress ? Tint.orange : Tint.blue,
            padding: compact ? 22 : 28
        ) {
            HStack(spacing: compact ? 14 : 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.3.layers.3d")
                        Text("\(CleaningCategory.scannable.count)-POINT LOCAL SCAN")
                            .tracking(0.7)
                        if stress {
                            Text("LOW SPACE")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Tint.orange.opacity(0.22)))
                        }
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))

                    Text(stress ? "Make room.\nKeep control." : "Scan first.\nDecide what goes.")
                        .font(.system(size: compact ? 30 : 36, weight: .bold))
                        .tracking(-1.0)
                        .foregroundStyle(.white)
                        .lineSpacing(-1)

                    Text("PureMac builds a reviewable cleanup plan on your Mac. Nothing is removed until you approve it.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 430, alignment: .leading)

                    Button {
                        appState.startSmartScan()
                    } label: {
                        Label("Scan My Mac", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Tint.blue)
                    .foregroundStyle(.white)
                    .accessibilityHint("Checks every cleanup category without deleting files")
                    .padding(.vertical, 2)

                    HStack(spacing: 14) {
                        trustLabel("Local", icon: "lock.shield.fill")
                        trustLabel("Private", icon: "eye.slash.fill")
                        trustLabel("Reviewable", icon: "checklist")
                    }

                    storagePlaque(
                        free: free,
                        total: total,
                        used: used,
                        percentUsed: percentUsed
                    )
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                storageVolumeScene(size: coreSize)
                    .frame(width: compact ? 270 : 340)
            }
            .frame(height: compact ? 296 : 326)
        }
    }

    private func trustLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.58))
    }

    private func storagePlaque(
        free: Int64,
        total: Int64,
        used: Int64,
        percentUsed: Double
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tint.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatted(free)) free")
                    .font(.system(size: 12.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(freeOfText(total: total))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.48))
            }

            StackedMeter(
                segments: [
                    .init(id: "used", value: Double(used), color: Tint.blue),
                    .init(id: "free", value: Double(max(0, free)), color: .white.opacity(0.10))
                ]
            )
            .frame(maxWidth: 150)

            Text(percentUsedText(percentUsed))
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
        )
        .frame(maxWidth: 470)
    }

    private func storageVolumeScene(size: CGFloat) -> some View {
        SmartCareCoreArtwork(phase: .idle, size: size)
            .accessibilityLabel("Twelve-layer storage inspection model")
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
        let clamped = max(0, min(1, usedPct))
        return String(
            format: String(localized: "%lld%% used"),
            Int64((clamped * 100).rounded())
        )
    }

    // MARK: - Care overview

    // Both lists are filtered against `scannable`, so a category withdrawn
    // there (see CleaningCategory.appModifying) drops out of the Care areas
    // counts instead of contributing a permanent zero.
    private var everydayCleanupCategories: [CleaningCategory] {
        [.systemJunk, .userCache, .mailAttachments, .trashBins, .largeFiles]
            .filter(CleaningCategory.scannable.contains)
    }

    private var developerCleanupCategories: [CleaningCategory] {
        [.aiApps, .xcodeJunk, .brewCache, .nodeCache, .dockerCache]
            .filter(CleaningCategory.scannable.contains)
    }

    private var careOverview: some View {
        let cleanupSize = summarySize(for: everydayCleanupCategories)
        let developerSize = summarySize(for: developerCleanupCategories)
        let compact = dashboardSize.width > 0 && dashboardSize.width < 900
        let supportingWidth: CGFloat = compact ? 136 : 178

        return HStack(spacing: 12) {
            CareModuleCard(
                icon: "sparkles.rectangle.stack.fill",
                tint: Tint.blue,
                title: "Cleanup",
                value: summaryValue(size: cleanupSize, categories: everydayCleanupCategories),
                detail: cleanupSize > 0
                    ? String(localized: "Ready for review")
                    : String(localized: "Caches, mail, trash, and large files"),
                prominent: true,
                showsDetail: !compact
            ) {
                onNavigate(.cleaning(largestCategory(in: everydayCleanupCategories) ?? .systemJunk))
            }
            .staggered(0)
            .frame(maxWidth: .infinity)

            CareModuleCard(
                icon: "hammer.circle.fill",
                tint: Tint.orange,
                title: "Developer",
                value: summaryValue(size: developerSize, categories: developerCleanupCategories),
                detail: developerSize > 0
                    ? String(localized: "Ready for review")
                    : String(localized: "Xcode and package tools"),
                showsDetail: !compact
            ) {
                onNavigate(.cleaning(largestCategory(in: developerCleanupCategories) ?? .xcodeJunk))
            }
            .staggered(1)
            .frame(width: supportingWidth)

            CareModuleCard(
                icon: "square.grid.2x2.fill",
                tint: Tint.purple,
                title: "Applications",
                value: "\(appState.installedApps.count)",
                detail: String(localized: "Installed apps"),
                showsDetail: !compact
            ) {
                onNavigate(.apps)
            }
            .staggered(2)
            .frame(width: supportingWidth)

            CareModuleCard(
                icon: "doc.questionmark.fill",
                tint: Tint.pink,
                title: "Orphaned Files",
                value: "\(appState.orphanedFiles.count)",
                detail: appState.orphanedFiles.isEmpty
                    ? String(localized: "No known leftovers")
                    : String(localized: "App leftovers to inspect"),
                showsDetail: !compact
            ) {
                onNavigate(.orphans)
            }
            .staggered(3)
            .frame(width: supportingWidth)
        }
        .frame(height: compact ? 128 : 134)
    }

    private func summarySize(for categories: [CleaningCategory]) -> Int64 {
        categories.reduce(0) { partial, category in
            partial + (appState.categoryResults[category]?.totalSize ?? 0)
        }
    }

    private func summaryValue(size: Int64, categories: [CleaningCategory]) -> String {
        if size > 0 {
            return formatted(size)
        }

        let scannedCount = categories.reduce(0) { count, category in
            count + (appState.categoryResults[category] == nil ? 0 : 1)
        }
        if scannedCount == 0 {
            return String(
                format: String(localized: "%lld checks"),
                Int64(categories.count)
            )
        }
        if scannedCount < categories.count {
            return String(
                format: String(localized: "%lld/%lld checked"),
                Int64(scannedCount),
                Int64(categories.count)
            )
        }
        return String(localized: "Clear")
    }

    private func largestCategory(in categories: [CleaningCategory]) -> CleaningCategory? {
        categories
            .compactMap { appState.categoryResults[$0] }
            .max { $0.totalSize < $1.totalSize }?
            .category
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
        let compact = dashboardSize.width > 0 && dashboardSize.width < 700
        let coreSize: CGFloat = compact ? 248 : 292

        return SmartCareStageSurface(tint: Tint.blue) {
            HStack(spacing: compact ? 16 : 30) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Scanning your Mac")
                            .font(.system(size: compact ? 26 : 31, weight: .bold))
                            .tracking(-0.5)
                    }
                    .foregroundStyle(.white)

                    // Category line slides up as the scan advances.
                    Text(currentlyInText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.68))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: appState.currentScanCategory)

                workingCore(
                    phase: .scanning(appState.scanProgress),
                    progress: appState.scanProgress,
                    label: "SCANNING",
                    size: coreSize
                )
            }
            .frame(height: compact ? 250 : 286)
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
        let compact = dashboardSize.width > 0 && dashboardSize.width < 700
        let coreSize: CGFloat = compact ? 248 : 292

        return SmartCareStageSurface(tint: isClean ? Tint.green : Tint.orange) {
            HStack(spacing: compact ? 16 : 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        isClean ? "ALL CLEAR" : "SCAN COMPLETE",
                        systemImage: isClean ? "checkmark.seal.fill" : "sparkles.rectangle.stack.fill"
                    )
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.72))

                    if isClean {
                        Text("Your Mac is in good shape.")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(.white)
                        Text("No removable junk was found in the areas PureMac checked.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.68))
                    } else {
                        Text("Ready to reclaim")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                        CountUpBytes(bytes: appState.totalJunkSize)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white)
                        Text(junkFoundDelta(count: appState.allResults.count))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.66))
                    }

                    HStack(spacing: 10) {
                        if !isClean && appState.totalSelectedSize > 0 {
                            Button {
                                showConfirmation = true
                            } label: {
                                Label(cleanSelectedLabel, systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(Tint.blue)
                            .foregroundStyle(.white)
                        }

                        Button("Scan Again") { appState.startSmartScan() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.white)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                resultCore(isClean: isClean, size: coreSize)
            }
            .frame(height: compact ? 250 : 286)
        }
    }

    private var cleanSelectedLabel: String {
        String(
            format: String(localized: "Clean %@"),
            ByteCountFormatter.string(fromByteCount: appState.totalSelectedSize, countStyle: .file)
        )
    }

    private var findingsGrid: some View {
        let columnCount = dashboardSize.width > 0 && dashboardSize.width < 900 ? 2 : 3
        let results = appState.allResults.sorted { $0.totalSize > $1.totalSize }

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columnCount),
            spacing: 14
        ) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                FindingTile(result: result) {
                    onNavigate(.cleaning(result.category))
                }
                .staggered(index)
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
        let compact = dashboardSize.width > 0 && dashboardSize.width < 700
        let coreSize: CGFloat = compact ? 248 : 292

        return SmartCareStageSurface(tint: Tint.orange) {
            HStack(spacing: compact ? 16 : 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cleaning safely…")
                        .font(.system(size: compact ? 26 : 31, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                    Text(percentCompleteText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.68))
                    ShimmerProgressBar(progress: appState.cleanProgress, tint: Tint.orange)
                        .frame(maxWidth: 320)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                workingCore(
                    phase: .cleaning(appState.cleanProgress),
                    progress: appState.cleanProgress,
                    label: "CLEANING",
                    size: coreSize
                )
            }
            .frame(height: compact ? 250 : 286)
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
        let compact = dashboardSize.width > 0 && dashboardSize.width < 700
        let coreSize: CGFloat = compact ? 248 : 292

        return SmartCareStageSurface(tint: Tint.green) {
            HStack(spacing: compact ? 16 : 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleanup complete")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                    CountUpBytes(bytes: appState.totalFreedSpace)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                    Text("freed")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.68))
                    Button("Done") { appState.scanState = .idle }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Tint.blue)
                        .foregroundStyle(.white)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                resultCore(isClean: true, size: coreSize)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                updateBurstOrigin(medalFrame: geo.frame(in: .named(dashboardSpace)))
                            }
                        }
                    )
            }
            .frame(height: compact ? 250 : 286)
        }
    }

    private func workingCore(
        phase: SmartCareCoreArtwork.Phase,
        progress: Double,
        label: LocalizedStringKey,
        size: CGFloat
    ) -> some View {
        let clamped = max(0, min(1, progress))
        let percentage = Int((clamped * 100).rounded())

        return SmartCareCoreArtwork(phase: phase, size: size)
            .frame(width: size, height: size)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue("\(percentage) percent")
    }

    private func resultCore(isClean: Bool, size: CGFloat) -> some View {
        SmartCareCoreArtwork(phase: isClean ? .success : .review, size: size)
            .frame(width: size, height: size)
            .frame(width: size, height: size)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isClean ? "All clear" : "Review scan results")
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Components

/// Deep, stateful dashboard plane inspired by premium Mac utilities while
/// preserving native SwiftUI content, focus, and accessibility behavior.
private struct SmartCareStageSurface<Content: View>: View {
    let tint: Color
    var padding: CGFloat = 28
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 28

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(TintGradient.smartCare)
                    RadialGradient(
                        colors: [tint.opacity(0.18), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 460
                    )
                    RadialGradient(
                        colors: [Tint.cyan.opacity(0.06), .clear],
                        center: .bottomLeading,
                        startRadius: 0,
                        endRadius: 420
                    )
                    LinearGradient(
                        colors: [.white.opacity(0.03), .clear, .black.opacity(0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.17), tint.opacity(0.10), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: tint.opacity(0.08), radius: 28, y: 12)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
            // The scenic surface is always dark, even when the surrounding app
            // is light, so semantic primary/secondary styles remain legible.
            .environment(\.colorScheme, .dark)
    }
}

private struct CareModuleCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let value: String
    let detail: String
    var prominent: Bool = false
    var showsDetail: Bool = true
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: prominent ? 11 : 8) {
                if prominent {
                    HStack(spacing: 9) {
                        IconTile(
                            systemName: icon,
                            tint: tint,
                            size: 32,
                            corner: 9,
                            glow: hovering,
                            vivid: true
                        )
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 5)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(hovering ? tint : Color.secondary.opacity(0.7))
                    }
                } else {
                    HStack {
                        IconTile(
                            systemName: icon,
                            tint: tint,
                            size: 25,
                            corner: 7,
                            glow: hovering
                        )
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(hovering ? tint : Color.secondary.opacity(0.65))
                    }
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.system(size: prominent ? 27 : 22, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                    if prominent && showsDetail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !prominent && showsDetail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, prominent ? 18 : 15)
            .padding(.vertical, prominent ? 15 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)
            .overlay(cardBorder)
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: prominent ? 68 : 38, height: 2)
                    .padding(.leading, prominent ? 18 : 15)
            }
            .shadow(
                color: hovering ? tint.opacity(0.13) : .black.opacity(colorScheme == .dark ? 0.11 : 0.06),
                radius: hovering ? 16 : 9,
                y: hovering ? 7 : 4
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
        .offset(y: hovering && !reduceMotion ? -3 : 0)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(prominent ? 0.105 : 0.045),
                                Color.white.opacity(colorScheme == .dark ? 0.025 : 0.24),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.15 : 0.65),
                        tint.opacity(hovering ? 0.30 : 0.10),
                        Color.primary.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }
}

private struct FindingTile: View {
    @EnvironmentObject var appState: AppState
    let result: CategoryResult
    let onReview: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFullySelected: Bool {
        appState.selectedCountInCategory(result.category) == result.itemCount
    }

    private var selection: Binding<Bool> {
        Binding(
            get: { isFullySelected },
            set: { selected in
                if selected {
                    appState.selectAllInCategory(result.category)
                } else {
                    appState.deselectAllInCategory(result.category)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Toggle(isOn: selection) {
                    Text(LocalizedStringKey(result.category.rawValue))
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)
                IconTile(
                    systemName: result.category.icon,
                    tint: result.category.color,
                    size: 34,
                    glow: hovering,
                    vivid: true
                )
            }

            Text(result.formattedSize)
                .font(.system(size: 27, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(itemsCountText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack {
                Text(selectedCountText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(result.category.color)
                Spacer()
                Button("Review", action: onReview)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(result.category.color)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [result.category.color.opacity(0.16), .clear],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(result.category.color.opacity(hovering ? 0.34 : 0.16), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.06),
                radius: hovering ? 14 : 8, y: hovering ? 6 : 3)
        .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
        .offset(y: hovering && !reduceMotion ? -2 : 0)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
    }

    private var itemsCountText: String {
        String(format: String(localized: "%lld items found"), Int64(result.itemCount))
    }

    private var selectedCountText: String {
        String(
            format: String(localized: "%lld selected"),
            Int64(appState.selectedCountInCategory(result.category))
        )
    }
}

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
