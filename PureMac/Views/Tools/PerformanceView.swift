import AppKit
import Charts
import SwiftUI

struct PerformanceView: View {
    private enum LoadState {
        case idle
        case loading
        case loaded(PerformanceInspection)
        case failed(String)
    }

    private let monitor = SystemMonitor.shared
    @State private var state: LoadState = .idle
    @State private var monitorOwner = UUID()
    @State private var pageIsVisible = false
    @State private var appIsActive = NSApplication.shared.isActive
    @State private var windowIsMinimized = false
    @State private var windowIsKey = false
    @State private var startupExpanded = false
    @State private var snapshotPendingDeletion: PerformanceSnapshot?
    @State private var deletingSnapshotID: String?
    @State private var deletionError: String?
    private let inspector = PerformanceInspector()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                PerformanceResources(isActive: resourcesAreActive, monitor: monitor)
                Divider()
                inspectionContent
            }
            .padding(20)
            .frame(maxWidth: 1020)
            .frame(maxWidth: .infinity)
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
        .task { await refresh() }
        .onAppear {
            pageIsVisible = true
            appIsActive = NSApplication.shared.isActive
            windowIsMinimized = WindowOpener.shared.mainWindow?.isMiniaturized ?? false
            windowIsKey = WindowOpener.shared.mainWindow?.isKeyWindow ?? false
            synchronizeMonitoring()
        }
        .onDisappear {
            pageIsVisible = false
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === WindowOpener.shared.mainWindow else { return }
            windowIsMinimized = true
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === WindowOpener.shared.mainWindow else { return }
            windowIsMinimized = false
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === WindowOpener.shared.mainWindow else { return }
            windowIsKey = true
            synchronizeMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === WindowOpener.shared.mainWindow else { return }
            windowIsKey = false
            synchronizeMonitoring()
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
            Text(deletionError ?? String(localized: "Unknown error"))
        }
    }

    private var header: some View {
        HStack {
            Text("Performance")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Open Activity Monitor") {
                openActivityMonitor()
            }
            .buttonStyle(.bordered)
        }
        .padding(.bottom, 2)
    }

    private var resourcesAreActive: Bool {
        pageIsVisible && appIsActive && windowIsKey && !windowIsMinimized
    }

    private func synchronizeMonitoring() {
        if resourcesAreActive {
            monitor.start(owner: monitorOwner, interval: 1.5)
        } else {
            monitor.stop(owner: monitorOwner)
        }
    }

    @ViewBuilder
    private var inspectionContent: some View {
        switch state {
        case .idle, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Inspecting startup items and local snapshots…").foregroundStyle(.secondary)
            }
        case .loaded(let inspection):
            if !inspection.issues.isEmpty {
                issuesSection(inspection.issues)
                Divider()
            }
            startupSection(inspection.startupItems)
            Divider()
            snapshotsSection(inspection.snapshots)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inspection stopped").font(.headline)
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Try Again") { Task { await refresh() } }
            }
        }
    }

    private func issuesSection(_ issues: [PerformanceInspectionIssue]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).fontWeight(.medium)
                        Text(issue.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Some information could not be read (\(issues.count))", systemImage: "exclamationmark.triangle")
        }
    }

    private func startupSection(_ items: [PerformanceStartupItem]) -> some View {
        DisclosureGroup(isExpanded: $startupExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Launch agents and daemons installed outside macOS system folders")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Login Items Settings") { openLoginItemsSettings() }.controlSize(.small)
                }
                if items.isEmpty {
                    Text("No launchd items found").foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Divider()
                            StartupItemRow(item: item) { reveal(item.sourceURL) }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Startup and background items").font(.headline)
                Spacer()
                Text(String(format: String(localized: "%lld found"), Int64(items.count)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("performance.startupDisclosure")
    }

    private func snapshotsSection(_ snapshots: [PerformanceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local snapshots").font(.headline)
                Text(String(localized: "\(snapshots.count) found")).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Time Machine Settings") { openTimeMachineSettings() }.controlSize(.small)
            }
            if snapshots.isEmpty {
                Text("No local snapshots reported").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshots) { snapshot in
                        Divider()
                        SnapshotRow(snapshot: snapshot, isDeleting: deletingSnapshotID == snapshot.id,
                                    deletionInProgress: deletingSnapshotID != nil) { snapshotPendingDeletion = snapshot }
                    }
                }
                Text("macOS does not report reliable per-snapshot sizes in this listing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { snapshotPendingDeletion != nil },
            set: { if !$0 { snapshotPendingDeletion = nil } }
        )
    }

    private var snapshotDeletionMessage: String {
        guard let snapshot = snapshotPendingDeletion else {
            return String(localized: "This permanently removes the selected Time Machine snapshot.")
        }
        return String(localized: "This permanently removes \(snapshot.identifier). Its size is unknown, and the action cannot be undone.")
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
            state = .idle
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

private struct PerformanceResources: View {
    let isActive: Bool
    let monitor: SystemMonitor
    @Environment(\.interfaceMotionEnabled) private var motionEnabled
    @State private var expanded = false
    @State private var readings: [SystemMonitor.Reading] = []

    private var latest: SystemMonitor.Reading? { readings.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("System Monitor").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Last minute").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(isActive ? "Live" : "Paused").font(.callout).foregroundStyle(.secondary)
            }

            historyChart(ending: latest?.date ?? Date())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                metric("CPU", symbol: "circle.fill", value: latest?.cpu,
                       detail: String(localized: "Total CPU capacity"), tint: .blue)
                metric("Memory in use", symbol: "diamond.fill", value: latest?.memory,
                       detail: memoryDetail, tint: .purple)
            }

            Divider().padding(.vertical, 4)
            DisclosureGroup(isExpanded: $expanded.animation(motionEnabled ? .easeInOut(duration: 0.18) : nil)) {
                if expanded {
                    ProcessResourcesView(isActive: isActive)
                }
            } label: {
                Text("Apps and processes").font(.headline)
            }
            .accessibilityIdentifier("performance.resourcesDisclosure")
        }
        .onReceive(monitor.$latestReading.compactMap { $0 }) { reading in
            guard isActive else { return }
            if let previous = latest {
                let interval = reading.date.timeIntervalSince(previous.date)
                guard interval != 0 else { return }
                if interval < 0 || interval > 3 { readings.removeAll(keepingCapacity: true) }
            }
            readings.removeAll { reading.date.timeIntervalSince($0.date) > 60 }
            readings.append(reading)
        }
    }

    private func metric(_ title: LocalizedStringKey, symbol: String, value: Double?, detail: String, tint: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 7)).foregroundStyle(tint).accessibilityHidden(true)
                Text(title)
            }
            Text(value?.formatted(.percent.precision(.fractionLength(0))) ?? "…")
                .monospacedDigit().gridColumnAlignment(.trailing)
            Text(detail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var memoryDetail: String {
        guard let latest, let used = latest.usedMemory else { return String(localized: "Unavailable") }
        return String(format: String(localized: "%@ of %@"), ByteCountFormatter.string(fromByteCount: used, countStyle: .memory),
                      ByteCountFormatter.string(fromByteCount: latest.totalMemory, countStyle: .memory))
    }

    private func historyChart(ending: Date) -> some View {
        Chart(readings) { reading in
            if let cpu = reading.cpu {
                LineMark(x: .value("Time", reading.date), y: .value("CPU", cpu), series: .value("Resource", "CPU"))
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                if reading.id == latest?.id {
                    PointMark(x: .value("Time", reading.date), y: .value("CPU", cpu))
                        .foregroundStyle(Color.blue)
                        .symbolSize(18)
                }
            }
            if let memory = reading.memory {
                LineMark(x: .value("Time", reading.date), y: .value("Memory", memory), series: .value("Resource", "Memory"))
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3]))
                if reading.id == latest?.id {
                    PointMark(x: .value("Time", reading.date), y: .value("Memory", memory))
                        .foregroundStyle(Color.purple)
                        .symbol(.diamond)
                        .symbolSize(20)
                }
            }
        }
        .chartXScale(domain: ending.addingTimeInterval(-60)...ending)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: [ending.addingTimeInterval(-60), ending.addingTimeInterval(-30), ending]) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel(centered: false, anchor: value.index == value.count - 1 ? .topTrailing : .topLeading) {
                        Text(date, format: .dateTime.hour().minute().second())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine()
                if let fraction = value.as(Double.self) {
                    AxisValueLabel { Text(fraction, format: .percent.precision(.fractionLength(0))) }
                }
            }
        }
        .frame(height: 116)
        .animation(motionEnabled && isActive ? .easeOut(duration: 0.2) : nil, value: latest?.id)
    }
}

private struct StartupItemRow: View {
    let item: PerformanceStartupItem
    let onReveal: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.label)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let attributes = [item.isDisabled ? String(localized: "Disabled") : item.domain.title]
                    + item.triggers.prefix(2)
                Text(attributes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)

                Text(item.program ?? String(localized: "Program not declared in this plist"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(item.sourceURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
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

        }
        .padding(.vertical, 7)
    }
}

private struct SnapshotRow: View {
    let snapshot: PerformanceSnapshot
    let isDeleting: Bool
    let deletionInProgress: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 7)
    }
}
