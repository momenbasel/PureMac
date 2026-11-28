import AppKit
import SwiftUI

/// Mounted only while the resource disclosure is open. Sampling also pauses
/// when PureMac is not the foreground application.
struct ProcessResourcesView: View {
    let isActive: Bool
    @StateObject private var monitor = ProcessResourceMonitor()
    @State private var sort: ProcessResourceSort = .cpu
    @State private var search = ""
    @State private var showAll = false
    @State private var isVisible = false

    var body: some View {
        let matchingConsumers = ProcessResourceMath.sorted(monitor.consumers, by: sort, search: search)
        let visibleConsumers = showAll || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? matchingConsumers : Array(matchingConsumers.prefix(8))
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Text("Apps and processes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Sort by", selection: $sort) {
                    Text("CPU").tag(ProcessResourceSort.cpu)
                    Text("Memory").tag(ProcessResourceSort.memory)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .accessibilityIdentifier("performance.processSort")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps and processes", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("performance.processSearch")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

            // Pausing keeps the last sample on screen under the notice.
            if !isActive {
                Label("Live updates paused", systemImage: "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if isActive && monitor.samplingFailed {
                Label("Process information is unavailable. Try Activity Monitor for more detail.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if isActive && monitor.consumers.isEmpty && monitor.isWarmingUp {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Measuring apps and processes…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else if visibleConsumers.isEmpty {
                if isActive || !monitor.consumers.isEmpty {
                    Text("No matching apps or processes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            } else {
                HStack {
                    Text("Name")
                    Spacer()
                    Text("CPU").frame(width: 92, alignment: .trailing)
                    Text("Memory").frame(width: 122, alignment: .trailing)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

                LazyVStack(spacing: 0) {
                    ForEach(visibleConsumers) { consumer in
                        ProcessResourceRow(consumer: consumer, icon: monitor.icon(for: consumer))
                        if consumer.id != visibleConsumers.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }

                if matchingConsumers.count > 8 && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(showAll ? String(localized: "Show top 8") : String(localized: "Show all apps and processes")) {
                        showAll.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("performance.showAllProcesses")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if isActive && monitor.isWarmingUp && !monitor.samplingFailed {
                    Text("CPU values appear after the next sample.")
                }
                if isActive && monitor.changedProcessCount > 0 {
                    Text("Some processes started or stopped since the last sample. Their values appear in the next one.")
                }
                if monitor.protectedProcessCount > 0 {
                    Text("System processes are not listed. Use Activity Monitor for those.")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            DisclosureGroup("About these readings") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CPU uses the Mac’s total capacity. App helpers are grouped with their app.")
                    Text("App memory shows resident memory, including shared pages. App totals can differ from the summary.")
                    Text("Memory estimate includes active, wired and compressed memory.")
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .onAppear {
            isVisible = true
            monitor.setActive(isActive)
        }
        .onDisappear {
            isVisible = false
            monitor.setActive(false)
        }
        .onChange(of: isActive) { active in
            monitor.setActive(isVisible && active)
        }
    }
}

private struct ProcessResourceRow: View {
    let consumer: ProcessResourceConsumer
    let icon: NSImage?
    private let memoryTotal = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            } else {
                ToolSymbol(systemName: "gearshape.2", tint: .secondary, size: 30)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(consumer.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if consumer.processCount == 1 {
                        Text("1 process")
                    } else {
                        Text("\(consumer.processCount) processes")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .help(consumer.applicationPath ?? consumer.name)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(cpuText)
                    .monospacedDigit()
                    .help(consumer.cpuIsPartial && consumer.cpuFraction != nil
                          ? String(localized: "Some of this app's processes have no CPU reading yet, so this total is partial.") : "")
                ProgressView(value: consumer.cpuFraction ?? 0)
                    .tint(Tint.accent)
                    .accessibilityHidden(true)
            }
            .frame(width: 92)
            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: consumer.residentBytes), countStyle: .memory))
                    .monospacedDigit()
                ProgressView(value: memoryTotal > 0 ? min(1, Double(consumer.residentBytes) / Double(memoryTotal)) : 0)
                    .tint(Tint.purple)
                    .accessibilityHidden(true)
            }
            .frame(width: 122)
        }
        .font(.system(size: 11.5, weight: .medium, design: .rounded))
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// A trailing plus marks a group whose CPU is the sum of its measured members only.
    private var cpuText: String {
        guard let cpu = consumer.cpuFraction else { return "—" }
        let value = cpu.formatted(.percent.precision(.fractionLength(1)))
        return consumer.cpuIsPartial ? value + "+" : value
    }
}
