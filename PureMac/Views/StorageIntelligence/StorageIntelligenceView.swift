import SwiftUI

struct StorageIntelligenceView: View {
    @ObservedObject var state: StorageIntelligenceState
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    pageHeader

                    if state.isRunning {
                        progressCard
                    }

                    if state.lifecycle == .failed {
                        errorCard
                    }

                    if let summary = state.summary {
                        summarySection(summary)
                        if let coverage = state.coverage {
                            coverageCard(coverage)
                        }
                        if let additional = state.additionalCoverage, additional.measuredRegionCount > 0 || additional.totalNewlyMeasuredBytes > 0 {
                            additionalCoverageCard(additional)
                        }
                        searchAndSortBar
                        if state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            categorySection
                        } else {
                            searchResultsSection
                        }
                        explanatoryDetails
                    } else if !state.isRunning && state.lifecycle != .failed {
                        idleCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle("Storage Intelligence")
        }
        .sheet(isPresented: $state.isShowingDiagnostics) {
            if let diagnostic = state.coverageDiagnostic {
                StorageCoverageDiagnosticsView(
                    diagnostic: diagnostic,
                    summary: state.summary,
                    attribution: state.attributionPresentation,
                    fullDiskAccessGranted: appState.hasFullDiskAccess,
                    dismiss: state.dismissDiagnostics
                )
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage Intelligence")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.45)
                    .accessibilityAddTraits(.isHeader)
                Text("See where your Mac storage is actually being used—without changing any files.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            if state.isRunning {
                Button("Cancel") { state.cancel() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Stops storage analysis and keeps any partial measurements returned")
            } else {
                Button {
                    state.analyze()
                } label: {
                    Label(state.hasCompletedReport ? "Analyze Again" : "Analyze Storage",
                          systemImage: "chart.bar.doc.horizontal")
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.blue)
                .accessibilityHint("Measures storage without modifying files")
            }
        }
    }

    private var idleCard: some View {
        CardSurface(padding: 24, elevation: .raised, tint: Tint.blue) {
            HStack(spacing: 20) {
                IconTile(systemName: "internaldrive.fill", tint: Tint.blue,
                         size: 52, corner: 14, vivid: true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Understand your storage")
                        .font(.system(size: 19, weight: .semibold))
                    Text("PureMac will measure visible files, application data, system locations, Docker storage, and APFS metadata. Results are for explanation and attribution only.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Analysis starts only when you request it", systemImage: "hand.tap")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tint.blue)
                        .padding(.top, 3)
                }
                Spacer()
            }
        }
    }

    private var progressCard: some View {
        CardSurface(padding: 16, tint: Tint.blue) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Analyzing storage", systemImage: "chart.bar.doc.horizontal")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if let progress = state.progress {
                        Text("\(progress.completedStages) of \(progress.totalStages) sources")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ProgressView(
                    value: Double(state.progress?.completedStages ?? 0),
                    total: Double(max(state.progress?.totalStages ?? 1, 1))
                )
                .accessibilityLabel("Storage analysis progress")
                .accessibilityValue(progressAccessibilityValue)

                if let stages = state.progress?.runningStages, !stages.isEmpty {
                    Text("Currently checking: \(stages.map(\.displayName).joined(separator: ", "))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Progress tracks analysis sources, not bytes, because directory workloads vary.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var progressAccessibilityValue: String {
        guard let progress = state.progress else { return "Starting" }
        return "\(progress.completedStages) of \(progress.totalStages) sources complete"
    }

    private var errorCard: some View {
        CardSurface(padding: 16, tint: Tint.orange) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: "exclamationmark.triangle.fill", tint: Tint.orange, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analysis could not finish")
                        .font(.system(size: 14, weight: .semibold))
                    Text(state.errorMessage ?? "An unexpected analysis error occurred.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ summary: StorageSummaryPresentation) -> some View {
        SectionHeader("Storage summary")
            .accessibilityAddTraits(.isHeader)

        CardSurface(padding: 16) {
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    summaryMetric("Total capacity", value: summary.totalCapacityBytes,
                                  icon: "internaldrive", tint: Tint.blue)
                    summaryMetric("Used", value: summary.usedBytes,
                                  icon: "chart.pie.fill", tint: Tint.purple)
                    summaryMetric("Free", value: summary.freeBytes,
                                  icon: "square.dashed", tint: Tint.green)
                    summaryMetric("Explained", value: summary.explainedAllocatedBytes,
                                  icon: "checkmark.circle.fill", tint: Tint.blue,
                                  note: state.coverage?.isPartial == true ? "Measured lower bound" : "Allocated on disk")
                    summaryMetric("Unexplained", value: summary.unexplainedBytes,
                                  icon: "questionmark.circle.fill", tint: Tint.orange,
                                  note: "Not classified as junk")
                    summaryMetric("Purgeable estimate", value: summary.purgeableEstimateBytes,
                                  icon: "gauge.with.dots.needle.50percent", tint: Tint.cyan,
                                  note: "Estimate, not guaranteed")
                }

                StorageAccountingBar(summary: summary)
            }
        }
    }

    private func summaryMetric(
        _ title: String,
        value: Int64?,
        icon: String,
        tint: Color,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, weight: .semibold))
            Text(StorageValueFormatter.string(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let note {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(StorageValueFormatter.string(value))\(note.map { ", \($0)" } ?? "")")
    }

    private func coverageCard(_ coverage: StorageCoveragePresentation) -> some View {
        let tint = coverage.isPartial ? Tint.orange : Tint.blue
        return CardSurface(padding: 14, tint: tint) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    systemName: coverage.isPartial ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                    tint: tint,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage coverage: \(coverage.isPartial ? "Partial" : "Configured roots complete")")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(coverage.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unexplained = coverage.unexplainedBytes {
                        Text("\(StorageValueFormatter.string(unexplained)) is not yet attributed by the current scan coverage.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if coverage.measurementIssueCount > 0 {
                        Text("\(coverage.measurementIssueCount) measurement issue\(coverage.measurementIssueCount == 1 ? "" : "s")")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.top, 3)
                        ForEach(topDiagnosticCounts(coverage.categoryCounts)) { item in
                            Text("• \(item.count) \(item.category.displayName.lowercased())")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if coverage.isPartial && coverage.knownLowerBoundBytes > 0 {
                        Text("Known measured storage in incomplete roots: \(StorageValueFormatter.string(coverage.knownLowerBoundBytes))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Button("View diagnostics") {
                        state.showDiagnostics()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let guidance = state.permissionGuidance(
                        fullDiskAccessGranted: appState.hasFullDiskAccess
                    ) {
                        if guidance.kind == .fullDiskAccessMayHelp {
                            Button("Review Access") {
                                permission.requestAccess(context: .general) {
                                    appState.checkFullDiskAccess()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Review Full Disk Access guidance")
                        } else {
                            Text("Permission denials remain despite Full Disk Access")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 165, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func additionalCoverageCard(_ additional: StorageAdditionalCoveragePresentation) -> some View {
        CardSurface(padding: 14, tint: Tint.blue) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    IconTile(systemName: "sparkles", tint: Tint.blue, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Additional Storage Coverage")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(StorageValueFormatter.string(additional.totalNewlyMeasuredBytes)) newly measured across \(additional.measuredRegionCount) region\(additional.measuredRegionCount == 1 ? "" : "s").")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let unexplained = additional.remainingUnexplainedBytes {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(StorageValueFormatter.string(unexplained))
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                            Text("remaining unmeasured")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !additional.largestDiscoveredRegions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Largest newly discovered regions:")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(additional.largestDiscoveredRegions.prefix(4)) { candidate in
                            HStack {
                                Text(candidate.name)
                                    .font(.system(size: 11, weight: .medium))
                                Text(candidate.normalizedPath)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(StorageValueFormatter.string(candidate.allocatedBytes))
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func topDiagnosticCounts(
        _ counts: [StorageCoverageDiagnosticCategoryCount]
    ) -> [StorageCoverageDiagnosticCategoryCount] {
        Array(counts.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.category.rawValue < $1.category.rawValue
        }.prefix(4))
    }

    private var searchAndSortBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search names, paths, or applications", text: Binding(
                    get: { state.searchText },
                    set: { state.updateSearch($0) }
                ))
                .textFieldStyle(.plain)
                if !state.searchText.isEmpty {
                    Button {
                        state.updateSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

            Picker("Sort", selection: Binding(
                get: { state.sortOrder },
                set: { state.updateSortOrder($0) }
            )) {
                ForEach(StorageIntelligenceSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityLabel("Storage item sorting")
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where storage is used")
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(state.categories) { category in
                    NavigationLink {
                        StorageCategoryDetailView(category: category, state: state)
                            .onAppear { state.selectCategory(category.id) }
                    } label: {
                        StorageCategoryCard(category: category)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("Search results")
                Spacer()
                Text("\(state.searchResults.count) matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if state.searchResults.isEmpty {
                CardSurface(padding: 18) {
                    Label("No matching storage entries", systemImage: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(state.searchResults) { result in
                        NavigationLink {
                            StorageNodeInspectorView(node: result.node, state: state)
                                .onAppear { state.selectNode(result.node) }
                        } label: {
                            StorageSearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var explanatoryDetails: some View {
        if state.dockerPresentation != nil || state.apfsPresentation != nil {
            SectionHeader("Non-additive explanations")
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                if let docker = state.dockerPresentation {
                    DockerStorageCard(docker: docker)
                }
                if let apfs = state.apfsPresentation {
                    APFSStorageCard(apfs: apfs)
                }
            }
        }
    }
}

private struct StorageAccountingBar: View {
    let summary: StorageSummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let total = max(summary.totalCapacityBytes ?? 0, 1)
                let explained = min(max(summary.explainedAllocatedBytes, 0), total)
                let unexplained = min(max(summary.unexplainedBytes ?? 0, 0), total - explained)
                HStack(spacing: 1) {
                    Rectangle()
                        .fill(Tint.blue)
                        .frame(width: proxy.size.width * CGFloat(Double(explained) / Double(total)))
                    Rectangle()
                        .fill(Tint.orange.opacity(0.75))
                        .frame(width: proxy.size.width * CGFloat(Double(unexplained) / Double(total)))
                    Rectangle().fill(Color.primary.opacity(0.08))
                }
                .clipShape(Capsule())
            }
            .frame(height: 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Storage accounting: \(StorageValueFormatter.string(summary.explainedAllocatedBytes)) explained, \(StorageValueFormatter.string(summary.unexplainedBytes)) unexplained, and \(StorageValueFormatter.string(summary.freeBytes)) free"
            )

            HStack(spacing: 14) {
                legend("Explained", color: Tint.blue,
                       value: summary.explainedAllocatedBytes)
                legend("Unexplained", color: Tint.orange.opacity(0.75),
                       value: summary.unexplainedBytes)
                legend("Free", color: Color.primary.opacity(0.18), value: summary.freeBytes)
            }
        }
    }

    private func legend(_ title: String, color: Color, value: Int64?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) \(StorageValueFormatter.string(value))")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct StorageCategoryCard: View {
    let category: StorageCategoryPresentation

    var body: some View {
        CardSurface(padding: 14, elevation: .standard, tint: category.id.tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    IconTile(systemName: category.id.icon, tint: category.id.tint, size: 36)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.id.title)
                        .font(.system(size: 14, weight: .semibold))
                    if category.isFilesystemAdditive {
                        Text(StorageValueFormatter.string(category.allocatedBytes))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(category.isOwnedElsewhere
                             ? "Host files counted under another category"
                             : "Allocated on this Mac")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Volume metadata")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Not additive to file totals")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if let prominent = category.prominentNode {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("Large: \(prominent.name)")
                            .lineLimit(1)
                        Spacer()
                        Text(StorageValueFormatter.string(prominent.allocatedSize))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(category.id.tint)
                } else if category.issueCount > 0 {
                    Label("\(category.issueCount) measurement issue\(category.issueCount == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tint.orange)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.id.title), \(category.isFilesystemAdditive ? StorageValueFormatter.string(category.allocatedBytes) : "non-additive volume metadata")")
    }
}

private struct StorageCategoryDetailView: View {
    let category: StorageCategoryPresentation
    @ObservedObject var state: StorageIntelligenceState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(systemName: category.id.icon, tint: category.id.tint, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.id.title)
                            .font(.system(size: 22, weight: .bold))
                        Text(category.id.explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if category.isFilesystemAdditive {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(StorageValueFormatter.string(category.allocatedBytes))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(category.isOwnedElsewhere ? "Counted elsewhere" : "Allocated on disk")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if category.id == .docker, let docker = state.dockerPresentation {
                    DockerStorageCard(docker: docker)
                }
                if category.id == .apfs, let apfs = state.apfsPresentation {
                    APFSStorageCard(apfs: apfs)
                }

                if category.roots.isEmpty && category.id != .apfs {
                    CardSurface(padding: 18) {
                        Label("No filesystem entries were reported for this category.",
                              systemImage: "tray")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else if !category.roots.isEmpty {
                    Text("Storage tree")
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(spacing: 6) {
                        ForEach(category.roots) { node in
                            StorageTreeNodeView(node: node, state: state)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(category.id.title)
        .background(AmbientBackdrop())
    }
}

private struct StorageTreeNodeView: View {
    let node: StorageNode
    @ObservedObject var state: StorageIntelligenceState
    @State private var isExpanded = false

    private var presentation: StorageNodePresentation {
        StorageNodePresentation(node: node)
    }

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                LazyVStack(spacing: 5) {
                    ForEach(node.children) { child in
                        StorageTreeNodeView(node: child, state: state)
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 5)
            } label: {
                row
            }
            .tint(.secondary)
        }
    }

    private var row: some View {
        StorageNodeRow(node: presentation, state: state)
            .onTapGesture { state.selectNode(presentation) }
    }
}

private struct StorageNodeRow: View {
    let node: StorageNodePresentation
    @ObservedObject var state: StorageIntelligenceState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isVirtualDisk ? "externaldrive.fill" : "doc.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(node.isVirtualDisk ? Tint.purple : Tint.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if node.isUnusuallyLarge {
                        nodeBadge("Large", icon: "exclamationmark.circle.fill", tint: Tint.orange)
                    }
                    if node.isSparseVirtualDisk {
                        nodeBadge("Sparse disk", icon: "externaldrive.badge.timemachine", tint: Tint.purple)
                    }
                    if node.hasIncompleteMeasurement {
                        nodeBadge("Incomplete", icon: "lock.trianglebadge.exclamationmark", tint: Tint.orange)
                    }
                }
                Text(node.ownerDisplayName ?? node.absolutePath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(StorageValueFormatter.string(node.allocatedSize))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if node.hasMaterialLogicalDifference {
                    Text("Logical \(StorageValueFormatter.string(node.logicalSize))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Button {
                state.revealInFinder(node)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!state.canRevealInFinder(node))
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(node.name) in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Reveal in Finder") { state.revealInFinder(node) }
                .disabled(!state.canRevealInFinder(node))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(nodeAccessibilityLabel)
    }

    private func nodeBadge(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }

    private var nodeAccessibilityLabel: String {
        var parts = [node.name, "used on disk \(StorageValueFormatter.string(node.allocatedSize))"]
        if node.hasMaterialLogicalDifference {
            parts.append("logical capacity \(StorageValueFormatter.string(node.logicalSize))")
        }
        if let owner = node.ownerDisplayName { parts.append("owned by \(owner)") }
        if node.hasIncompleteMeasurement { parts.append("measurement incomplete") }
        return parts.joined(separator: ", ")
    }
}

private struct StorageSearchResultRow: View {
    let result: StorageSearchResult

    var body: some View {
        CardSurface(padding: 10, elevation: .flat) {
            HStack(spacing: 10) {
                IconTile(systemName: result.categoryID.icon, tint: result.categoryID.tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.node.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(result.node.absolutePath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(StorageValueFormatter.string(result.node.allocatedSize))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StorageNodeInspectorView: View {
    let node: StorageNodePresentation
    @ObservedObject var state: StorageIntelligenceState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    IconTile(systemName: node.isVirtualDisk ? "externaldrive.fill" : "doc.fill",
                             tint: node.isVirtualDisk ? Tint.purple : Tint.blue,
                             size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name).font(.system(size: 21, weight: .bold))
                        Text(node.absolutePath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                CardSurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 11) {
                        inspectorRow("Used on disk", StorageValueFormatter.string(node.allocatedSize))
                        inspectorRow("Logical size", StorageValueFormatter.string(node.logicalSize))
                        inspectorRow("Accessibility", node.accessibility.displayName)
                        if let category = node.storageCategory {
                            inspectorRow("Informational category", category)
                        }
                        if let owner = node.ownerDisplayName {
                            inspectorRow("Owning application", owner)
                        }
                        if node.isVirtualDisk {
                            inspectorRow("Virtual disk", node.isSparseVirtualDisk ? "Sparse" : "Detected")
                        }
                        if node.hasIncompleteMeasurement {
                            inspectorRow("Measurement", "Incomplete (\(node.issueCount) issue\(node.issueCount == 1 ? "" : "s"))")
                        }
                    }
                }

                Button {
                    state.revealInFinder(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(!state.canRevealInFinder(node))
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(node.name)
        .background(AmbientBackdrop())
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

private struct DockerStorageCard: View {
    let docker: StorageDockerPresentation

    var body: some View {
        CardSurface(padding: 16, tint: Tint.purple) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("Docker storage", systemImage: "shippingbox.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    StatusChip(
                        label: docker.runtimeLocation == .remote ? "Remote context" : "Non-additive runtime",
                        systemImage: docker.runtimeLocation == .remote ? "network" : "info.circle.fill",
                        tint: docker.runtimeLocation == .remote ? Tint.orange : Tint.purple
                    )
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local Mac footprint")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(StorageValueFormatter.string(docker.localFootprintBytes))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Host files on this Mac")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Divider().frame(height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Runtime breakdown")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(StorageValueFormatter.string(docker.runtimeReportedBytes))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Never added to Mac usage")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !docker.runtimeCategories.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(docker.runtimeCategories) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(StorageValueFormatter.string(item.totalBytes))
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Text(docker.relationshipMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(docker.runtimeLocation == .remote ? Tint.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Docker local Mac footprint \(StorageValueFormatter.string(docker.localFootprintBytes)). \(docker.relationshipMessage)")
    }
}

private struct APFSStorageCard: View {
    let apfs: StorageAPFSPresentation

    var body: some View {
        CardSurface(padding: 16, tint: Tint.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("APFS volume", systemImage: "internaldrive.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    StatusChip(label: "Non-additive metadata", systemImage: "info.circle.fill", tint: Tint.cyan)
                }

                HStack(spacing: 16) {
                    apfsMetric("Capacity", apfs.totalCapacityBytes)
                    apfsMetric("Free", apfs.freeBytes)
                    apfsMetric("Purgeable estimate", apfs.purgeableEstimateBytes)
                }

                Divider()

                HStack {
                    Text("Snapshots")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("Shared extents; not added to file totals")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                if apfs.snapshots.isEmpty {
                    Text("No local snapshots were reported.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apfs.snapshots.prefix(5)) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                Text(snapshot.type.displayName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(snapshot.sizeIsReliable
                                 ? StorageValueFormatter.string(snapshot.sizeBytes)
                                 : "Unknown")
                                .font(.system(size: 10.5, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    if apfs.snapshots.count > 5 {
                        Text("\(apfs.snapshots.count - 5) additional snapshots")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("APFS capacity \(StorageValueFormatter.string(apfs.totalCapacityBytes)), free \(StorageValueFormatter.string(apfs.freeBytes)), purgeable estimate \(StorageValueFormatter.string(apfs.purgeableEstimateBytes)), \(apfs.snapshots.count) snapshots, snapshot storage is non-additive")
    }

    private func apfsMetric(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                             Text(StorageValueFormatter.string(value))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StorageCoverageDiagnosticsView: View {
    let diagnostic: StorageCoverageDiagnostic
    let summary: StorageSummaryPresentation?
    let attribution: StorageAttributionPresentation?
    let fullDiskAccessGranted: Bool
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let attribution {
                    Section("Unexplained storage attribution") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Evidence-based attribution explaining volume storage composition and the remaining unexplained gap.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Used")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(StorageValueFormatter.string(attribution.volumeUsedBytes))
                                        .font(.caption.weight(.semibold))
                                }
                                Spacer()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Explained")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(StorageValueFormatter.string(attribution.explainedAllocatedBytes))
                                        .font(.caption.weight(.semibold))
                                }
                                Spacer()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Unexplained")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(StorageValueFormatter.string(attribution.unexplainedBytes))
                                        .font(.caption.weight(.semibold))
                                }
                                Spacer()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Residual")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(StorageValueFormatter.string(attribution.residualUnattributedBytes))
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(.vertical, 2)

                        ForEach(StorageAttributionCategory.allCases, id: \.self) { category in
                            let items = attribution.attributionItems.filter { $0.category == category }
                            if !items.isEmpty {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(category.explanation)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ForEach(items) { item in
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(alignment: .firstTextBaseline) {
                                                    Text(item.name)
                                                        .fontWeight(.medium)
                                                    Spacer()
                                                    statusBadge(for: item.status)
                                                    if let bytes = item.allocatedBytes {
                                                        Text(StorageValueFormatter.string(bytes))
                                                            .font(.caption.weight(.medium))
                                                            .monospacedDigit()
                                                    }
                                                }
                                                if let path = item.path {
                                                    Text(path)
                                                        .font(.caption2.monospaced())
                                                        .foregroundStyle(.secondary)
                                                        .textSelection(.enabled)
                                                }
                                                Text(item.explanation)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(category.displayName)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if !attribution.dataVolumeRoots.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Top-level regions and firmlinked roots discovered on /System/Volumes/Data.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(attribution.dataVolumeRoots) { root in
                                        HStack(alignment: .firstTextBaseline) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 6) {
                                                    Text(root.name)
                                                        .fontWeight(.medium)
                                                    classificationBadge(for: root.classification)
                                                }
                                                Text(root.normalizedPath)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                            Spacer()
                                            if let bytes = root.allocatedBytes {
                                                Text(StorageValueFormatter.string(bytes))
                                                    .font(.caption.weight(.semibold))
                                                    .monospacedDigit()
                                            } else {
                                                Text("—")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("Data-volume root attribution")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("\(attribution.dataVolumeRoots.count) roots")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Coverage gaps") {
                    if diagnostic.coverageGaps.isEmpty {
                        Text("No structural coverage gaps were discovered.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(diagnostic.coverageGaps) { gap in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(gap.name).fontWeight(.medium)
                                    Spacer()
                                    Text(gap.confidence.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let path = gap.absolutePath {
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Text(gap.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Measurement issues") {
                    if diagnostic.measurementIssues.totalIssueCount == 0 {
                        Text("No measurement issues were recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(diagnostic.measurementIssues.totalIssueCount) unique issue\(diagnostic.measurementIssues.totalIssueCount == 1 ? "" : "s"), grouped by cause and source.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(diagnostic.measurementIssues.groups) { group in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(group.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let errorCode = group.posixErrorCode {
                                        Text("POSIX errno: \(errorCode)")
                                            .font(.caption.monospaced())
                                    }
                                    if group.contributingSources.count > 1 {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Observed by:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                            ForEach(group.contributingSources, id: \.self) { source in
                                                Text("• \(source.displayName)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    if !group.representativePaths.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Representative paths:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                            ForEach(group.representativePaths, id: \.self) { path in
                                                Text(path)
                                                    .font(.caption.monospaced())
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(groupTitle(for: group))
                                        if group.contributingSources.count > 1 {
                                            Text("Observed by \(group.contributingSources.count) sources")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(group.source.displayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(group.count)")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Analyzer status") {
                    ForEach(diagnostic.analyzerStatuses) { status in
                        HStack {
                            Text(status.analyzer.displayName)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(status.state.displayName)
                                    .font(.callout.weight(.medium))
                                if status.issueCount > 0 {
                                    Text("\(status.issueCount) issue\(status.issueCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Unexplained-space explanation") {
                    if let summary, let used = summary.usedBytes {
                        Text("PureMac measured \(StorageValueFormatter.string(summary.explainedAllocatedBytes)) of the \(StorageValueFormatter.string(used)) currently used. \(StorageValueFormatter.string(summary.unexplainedBytes)) is not yet attributed by the current scan coverage.")
                    }
                    ForEach(diagnostic.unexplainedSpaceExplanations) { explanation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(explanation.title).fontWeight(.medium)
                            Text(explanation.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if diagnostic.permissionDeniedIssueCount == 0 {
                        Text("No recorded diagnostic supports recommending Full Disk Access for this result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if fullDiskAccessGranted {
                        Text("Full Disk Access is detected, but macOS still protects certain system-managed locations (e.g. audit logs, document revisions, and system databases). See the measurement issues above for details.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Full Disk Access is not detected. Granting Full Disk Access may allow PureMac to inspect additional application and system locations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Storage Diagnostics")
            .frame(minWidth: 720, minHeight: 620)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
    }

    private func groupTitle(for group: StorageCoverageDiagnosticIssueGroup) -> String {
        let categoryName = group.category.displayName
        if let root = group.canonicalRoot {
            return "\(categoryName) — \(root.displayName)"
        }
        if let first = group.representativePaths.first {
            let parent = StoragePathNormalizer.parentPath(of: first)
            if !parent.isEmpty && parent != "/" {
                return "\(categoryName) — \(parent)"
            }
        }
        return "\(categoryName) — \(group.source.displayName)"
    }

    private func statusBadge(for status: StorageAttributionStatus) -> some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBackground(for: status))
            .foregroundColor(badgeForeground(for: status))
            .clipShape(Capsule())
    }

    private func classificationBadge(for classification: DataVolumeRegionClassification) -> some View {
        Text(classification.displayName)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    private func badgeBackground(for status: StorageAttributionStatus) -> Color {
        switch status {
        case .measured: return Color.green.opacity(0.15)
        case .partial: return Color.orange.opacity(0.15)
        case .protectedUnreadable: return Color.purple.opacity(0.15)
        case .estimate: return Color.blue.opacity(0.15)
        case .nonAdditive: return Color.cyan.opacity(0.15)
        case .unknown: return Color.secondary.opacity(0.15)
        }
    }

    private func badgeForeground(for status: StorageAttributionStatus) -> Color {
        switch status {
        case .measured: return .green
        case .partial: return .orange
        case .protectedUnreadable: return .purple
        case .estimate: return .blue
        case .nonAdditive: return .cyan
        case .unknown: return .secondary
        }
    }
}

private enum StorageValueFormatter {
    static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

private extension StorageCoverageDiagnosticCategory {
    var displayName: String {
        switch self {
        case .permissionDenied: return "Permission denied"
        case .inaccessible: return "Inaccessible"
        case .enumerationFailure: return "Enumeration failure"
        case .metadataFailure: return "Metadata failure"
        case .differentVolumeBoundary: return "Filesystem boundary"
        case .cancelled: return "Cancelled"
        case .missingOptionalRoot: return "Missing optional root"
        case .failedAnalyzer: return "Failed analyzer"
        case .uncoveredFilesystemRegion: return "Uncovered filesystem region"
        case .nonAdditiveAPFSStorage: return "Non-additive APFS storage"
        case .possibleSharedExtentAccounting: return "Possible shared extents"
        case .concurrentFilesystemChange: return "Path changed during analysis"
        case .unknown: return "Unknown"
        }
    }
}

private extension StorageCanonicalRoot {
    var displayName: String {
        switch self {
        case .userHomeVisibleStorage: return "User Files"
        case .applicationSupport: return "Application Support"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .systemLibrary: return "System Library"
        case .privateStorage: return "Private / System State"
        case .dataVolumeHiddenStorage: return "Data-volume metadata"
        case .opt: return "/opt"
        case .usrLocal: return "/usr/local"
        case .additionalCoverageGap: return "Additional Storage Coverage"
        }
    }
}

private extension StorageCoverageDiagnosticSource {
    var displayName: String {
        switch self {
        case let .analyzer(stage): return stage.displayName
        case let .canonicalRoot(root): return root.displayName
        case .coverageDiscovery: return "Coverage discovery"
        case .reconciliation: return "Storage reconciliation"
        case .apfs: return "APFS metadata"
        }
    }
}

private extension StorageMeasurementConfidence {
    var displayName: String {
        switch self {
        case .completeMeasurement: return "Measured"
        case .knownLowerBound: return "Known lower bound"
        case .partialCoverage: return "Partial coverage"
        case .nonAdditiveMetadata: return "Non-additive"
        case .unmeasured: return "Unmeasured"
        }
    }
}

private extension StorageAnalyzerDiagnosticState {
    var displayName: String {
        switch self {
        case .complete: return "Complete"
        case .knownLowerBound: return "Known lower bound"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .optionalRootMissing: return "Optional root missing"
        case .nonAdditiveMetadata: return "Non-additive metadata"
        }
    }
}

private extension StorageIntelligenceCategoryID {
    var icon: String {
        switch self {
        case .userFiles: return "person.crop.circle.fill"
        case .applicationSupport: return "app.badge.fill"
        case .containers: return "shippingbox.fill"
        case .groupContainers: return "square.stack.3d.up.fill"
        case .systemLibrary: return "building.columns.fill"
        case .privateSystemState: return "gearshape.2.fill"
        case .hiddenData: return "eye.slash.fill"
        case .developerThirdParty: return "hammer.fill"
        case .docker: return "shippingbox.and.arrow.backward.fill"
        case .apfs: return "internaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .userFiles: return Tint.blue
        case .applicationSupport: return Tint.purple
        case .containers: return Tint.cyan
        case .groupContainers: return Tint.pink
        case .systemLibrary: return Tint.orange
        case .privateSystemState: return Tint.yellow
        case .hiddenData: return Tint.orange
        case .developerThirdParty: return Tint.green
        case .docker: return Tint.purple
        case .apfs: return Tint.cyan
        }
    }
}

private extension StorageAnalyzerStage {
    var displayName: String {
        switch self {
        case .apfsVolume: return "APFS volume"
        case .userHomeStorage: return "user files"
        case .applicationSupport: return "Application Support"
        case .containers: return "containers"
        case .groupContainers: return "group containers"
        case .systemLibrary: return "System Library"
        case .privateStorage: return "private system state"
        case .dataVolumeHiddenStorage: return "hidden Data-volume storage"
        case .developerSystemStorage: return "developer and third-party storage"
        case .dockerStorage: return "Docker"
        case .coverageExpansion: return "additional storage coverage"
        }
    }
}

private extension StorageAccessibility {
    var displayName: String {
        switch self {
        case .accessible: return "Accessible"
        case .partiallyAccessible: return "Partially accessible"
        case .inaccessible: return "Inaccessible"
        case .skippedDifferentVolume: return "Different mounted volume"
        case .cancelled: return "Analysis cancelled"
        }
    }
}

private extension APFSSnapshotType {
    var displayName: String {
        switch self {
        case .timeMachine: return "Time Machine"
        case .operatingSystemUpdate: return "macOS update"
        case .otherAPFS: return "Other APFS"
        case .unknown: return "Unknown type"
        }
    }
}
