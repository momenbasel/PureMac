import AppKit
import SwiftUI

struct PerformanceView: View {
    private enum LoadState {
        case idle
        case loading
        case loaded(PerformanceInspection)
        case failed(String)
    }

    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var startupExpanded = false
    @State private var state: LoadState = .idle
    @State private var snapshotPendingDeletion: PerformanceSnapshot?
    @State private var deletingSnapshotID: String?
    @State private var deletionError: String?
    private let inspector = PerformanceInspector()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                // Only a few expandable cards: eager layout avoids unstable lazy height estimates.
                VStack(alignment: .leading, spacing: 14) {
                    header
                    liveResources
                    inspectionContent
                }
                .padding(24)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Performance")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Inspect startup items and local snapshots again")
            }
        }
        .task {
            monitor.start(interval: 1.5)
            await refresh()
        }
        .onDisappear {
            monitor.stop()
        }
        .alert("Delete local snapshot?", isPresented: deletionConfirmationPresented) {
            Button("Cancel", role: .cancel) {
                snapshotPendingDeletion = nil
            }
            Button("Delete Snapshot", role: .destructive) {
                guard let snapshot = snapshotPendingDeletion else { return }
                snapshotPendingDeletion = nil
                Task { await delete(snapshot) }
            }
        } message: {
            Text(snapshotDeletionMessage)
        }
        .alert("Snapshot could not be deleted", isPresented: deletionErrorPresented) {
            Button("OK", role: .cancel) {
                deletionError = nil
            }
        } message: {
            Text(deletionError ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemName: "gauge.with.dots.needle.67percent", tint: Tint.accent, size: 44, corner: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text("Performance")
                    .font(.system(size: 26, weight: .bold))
                Text("See current resource use and review what starts in the background.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Activity Monitor") {
                openActivityMonitor()
            }
            .buttonStyle(.bordered)
        }
        .padding(.bottom, 2)
    }

    private var liveResources: some View {
        CardSurface(padding: 18, elevation: .standard, tint: Tint.accent) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionHeader("Live resources")
                    Spacer()
                    StatusChip(label: "Live", systemImage: "circle.fill", tint: Tint.green)
                }

                HStack(spacing: 26) {
                    ResourceMeter(
                        title: "CPU",
                        value: monitor.cpuUsage,
                        detail: "\(Int((monitor.cpuUsage * 100).rounded()))%",
                        tint: Tint.accent
                    )
                    Divider()
                        .frame(height: 52)
                    ResourceMeter(
                        title: "Memory pressure use",
                        value: monitor.memoryFraction,
                        detail: memoryDetail,
                        tint: Tint.purple
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var inspectionContent: some View {
        switch state {
        case .idle, .loading:
            CardSurface(padding: 28, elevation: .flat) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting startup items and local snapshots…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        case .loaded(let inspection):
            if !inspection.issues.isEmpty {
                issuesCard(inspection.issues)
            }
            startupCard(inspection.startupItems)
            snapshotsCard(inspection.snapshots)
        case .failed(let message):
            CardSurface(padding: 18, elevation: .standard, tint: Tint.orange) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemName: "exclamationmark.triangle.fill", tint: Tint.orange, size: 32, corner: 9)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Inspection stopped")
                            .font(.system(size: 14, weight: .semibold))
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Try Again") {
                        Task { await refresh() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func issuesCard(_ issues: [PerformanceInspectionIssue]) -> some View {
        CardSurface(padding: 16, elevation: .flat, tint: Tint.orange) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(issue.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(
                    "Some information could not be read (\(issues.count))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tint.orange)
            }
        }
    }

    private func startupCard(_ items: [PerformanceStartupItem]) -> some View {
        CardSurface(padding: 18, elevation: .standard) {
            DisclosureGroup(isExpanded: $startupExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Launch agents and daemons installed outside macOS system folders")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Login Items Settings") {
                            openLoginItemsSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Divider()
                    if items.isEmpty {
                        EmptyInspectionRow(
                            systemImage: "checkmark.circle.fill",
                            title: "No launchd items found",
                            detail: "The inspected user and third-party launch folders are empty."
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                StartupItemRow(item: item) { reveal(item.sourceURL) }
                                if index < items.count - 1 {
                                    Divider().padding(.leading, 58)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 14)
            } label: {
                HStack(spacing: 10) {
                    IconTile(systemName: "switch.2", tint: Tint.accent, size: 30, corner: 8)
                    Text("Startup and background items")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    StatusChip(label: String(format: String(localized: "%lld found"), Int64(items.count)), tint: Tint.accent)
                }
            }
            .accessibilityIdentifier("performance.startupDisclosure")
        }
    }

    private func snapshotsCard(_ snapshots: [PerformanceSnapshot]) -> some View {
        CardSurface(padding: 0, elevation: .standard) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    IconTile(systemName: "clock.arrow.circlepath", tint: Tint.purple, size: 30, corner: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local snapshots")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Time Machine snapshots can be reviewed and removed individually")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusChip(label: "\(snapshots.count) found", tint: Tint.purple)
                    Button("Time Machine Settings") {
                        openTimeMachineSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(18)

                Divider()

                if snapshots.isEmpty {
                    EmptyInspectionRow(
                        systemImage: "clock.badge.checkmark.fill",
                        title: "No local snapshots reported",
                        detail: "Time Machine did not report any snapshots for the startup disk."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                            SnapshotRow(
                                snapshot: snapshot,
                                isDeleting: deletingSnapshotID == snapshot.id,
                                deletionInProgress: deletingSnapshotID != nil
                            ) {
                                snapshotPendingDeletion = snapshot
                            }
                            if index < snapshots.count - 1 {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("macOS does not report reliable per-snapshot sizes in this listing.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.025))
                }
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var memoryDetail: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return "\(formatter.string(fromByteCount: monitor.memoryUsed)) of \(formatter.string(fromByteCount: monitor.memoryTotal))"
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { snapshotPendingDeletion != nil },
            set: { if !$0 { snapshotPendingDeletion = nil } }
        )
    }

    private var snapshotDeletionMessage: String {
        guard let snapshot = snapshotPendingDeletion else {
            return "This permanently removes the selected Time Machine snapshot."
        }
        return "This permanently removes \(snapshot.identifier). Its size is unknown, and the action cannot be undone."
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        state = .loading
        do {
            state = .loaded(try await inspector.inspect())
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func delete(_ snapshot: PerformanceSnapshot) async {
        guard deletingSnapshotID == nil else { return }
        deletingSnapshotID = snapshot.id
        defer { deletingSnapshotID = nil }
        do {
            try await inspector.deleteSnapshot(snapshot)
            state = .loaded(try await inspector.inspect())
        } catch is CancellationError {
            return
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTimeMachineSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.TimeMachine-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ResourceMeter: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            ProgressView(value: min(1, max(0, value)))
                .tint(tint)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StartupItemRow: View {
    let item: PerformanceStartupItem
    let onReveal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(
                systemName: item.domain == .systemDaemon ? "gearshape.2.fill" : "bolt.horizontal.circle.fill",
                tint: item.isDisabled ? Color.secondary : Tint.accent,
                size: 28,
                corner: 8
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    StatusChip(
                        label: item.isDisabled ? "Disabled" : item.domain.title,
                        tint: item.isDisabled ? Color.secondary : Tint.accent
                    )
                    ForEach(item.triggers.prefix(2), id: \.self) { trigger in
                        StatusChip(label: trigger, tint: Tint.purple)
                    }
                }

                Text(item.program ?? "Program not declared in this plist")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(item.program == nil ? Tint.orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(item.sourceURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button(action: onReveal) {
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal plist in Finder")
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(hovering ? Color.primary.opacity(0.025) : Color.clear)
        .onHover { hovering = $0 }
    }
}

private struct SnapshotRow: View {
    let snapshot: PerformanceSnapshot
    let isDeleting: Bool
    let deletionInProgress: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(
                systemName: snapshot.kind == .systemUpdate ? "macbook.and.iphone" : "clock.arrow.circlepath",
                tint: snapshot.kind == .systemUpdate ? Tint.orange : Tint.purple,
                size: 28,
                corner: 8
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(snapshot.kind.title)
                        .font(.system(size: 13, weight: .medium))
                    if let date = snapshot.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot.identifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text("Size unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if PerformanceInspector.deletionTimestamp(for: snapshot) != nil {
                    Button(role: .destructive, action: onDelete) {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(deletionInProgress)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct EmptyInspectionRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(Tint.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }
}
