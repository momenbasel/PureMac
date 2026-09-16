import AppKit
import Darwin
import Foundation

struct ProcessResourceConsumer: Identifiable, Sendable {
    let id: String
    var name: String
    let applicationPath: String?
    var cpuFraction: Double?
    var residentBytes: UInt64
    var processCount: Int
}

enum ProcessResourceSort: String, CaseIterable, Identifiable {
    case cpu, memory
    var id: Self { self }
}

/// Includes the kernel start time so a recycled PID never inherits CPU counters.
struct ProcessResourceReading: Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let name: String
    let cpuTicks: UInt64
    let residentBytes: UInt64
    let sampledAt: UInt64

    var identity: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
}

enum ProcessResourceMath {
    /// The first bundle owns nested helpers, XPC services and embedded apps.
    static func applicationPath(for executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let components = (executablePath as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components.prefix(through: index)))
    }

    static func cpuFraction(current: ProcessResourceReading, previous: ProcessResourceReading?, processorCount: Int, nanosecondsPerTick: Double = 1) -> Double? {
        guard let previous, previous.identity == current.identity,
              previous.executablePath == current.executablePath,
              current.sampledAt > previous.sampledAt,
              current.cpuTicks >= previous.cpuTicks,
              processorCount > 0, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0 else { return nil }
        let elapsed = Double(current.sampledAt - previous.sampledAt)
        let cpu = Double(current.cpuTicks - previous.cpuTicks) * nanosecondsPerTick
        return min(1, max(0, cpu / elapsed / Double(processorCount)))
    }

    static func consumers(readings: [ProcessResourceReading], previous: [String: ProcessResourceReading], processorCount: Int, nanosecondsPerTick: Double = 1) -> [ProcessResourceConsumer] {
        var groups: [String: ProcessResourceConsumer] = [:]
        for reading in readings {
            let application = applicationPath(for: reading.executablePath)
            // Unknown executable paths remain separate; similarly named processes
            // must not be attributed to an application without evidence.
            let id = application.map { "app:\($0)" }
                ?? (reading.executablePath.isEmpty ? "pid:\(reading.identity)" : "exe:\(reading.executablePath)")
            let cpu = cpuFraction(current: reading, previous: previous[reading.identity], processorCount: processorCount, nanosecondsPerTick: nanosecondsPerTick)
            if var group = groups[id] {
                group.residentBytes = group.residentBytes.addingReportingOverflow(reading.residentBytes).overflow
                    ? UInt64.max : group.residentBytes + reading.residentBytes
                group.processCount += 1
                // Any unknown member means this group's first interval is incomplete.
                if let total = group.cpuFraction, let cpu {
                    group.cpuFraction = min(1, total + cpu)
                } else {
                    group.cpuFraction = nil
                }
                groups[id] = group
            } else {
                let name = application.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                    ?? reading.name
                groups[id] = ProcessResourceConsumer(id: id, name: name, applicationPath: application,
                                                     cpuFraction: cpu, residentBytes: reading.residentBytes, processCount: 1)
            }
        }
        return Array(groups.values)
    }

    static func sorted(_ consumers: [ProcessResourceConsumer], by sort: ProcessResourceSort, search: String = "") -> [ProcessResourceConsumer] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return consumers.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted {
            switch sort {
            case .cpu:
                if $0.cpuFraction != $1.cpuFraction { return ($0.cpuFraction ?? -1) > ($1.cpuFraction ?? -1) }
                if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            case .memory:
                if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

private struct ProcessResourceSample: Sendable {
    let consumers: [ProcessResourceConsumer]
    let unavailableProcessCount: Int
    let failed: Bool
    let warmingUp: Bool
}

/// A serial actor keeps all libproc calls and counter bookkeeping off the UI
/// thread. No subprocess, elevated privileges or process-control APIs are used.
private actor ProcessResourceSampler {
    private var previous: [String: ProcessResourceReading] = [:]
    // XNU fill_taskprocinfo returns Mach absolute ticks, not nanoseconds:
    // https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c
    private let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return .nan }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    func sample() -> ProcessResourceSample {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            previous.removeAll()
            return ProcessResourceSample(consumers: [], unavailableProcessCount: 0, failed: true, warmingUp: true)
        }
        // Headroom accommodates processes created between enumeration calls.
        var pids = [Int32](repeating: 0, count: Int(estimate) + 256)
        let capacityBytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, capacityBytes) }
        guard count > 0 else {
            previous.removeAll()
            return ProcessResourceSample(consumers: [], unavailableProcessCount: 0, failed: true, warmingUp: true)
        }
        var readings: [ProcessResourceReading] = []
        var unavailable = Int(count) >= pids.count ? 1 : 0
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            if Task.isCancelled { break }
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.stride)
            errno = 0
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else {
                // An exited process is normal churn, not a permission failure.
                if errno != ESRCH { unavailable += 1 }
                continue
            }
            // Re-read the path: exec can change the executable without changing
            // the PID or kernel start time. This also avoids stale app attribution.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let bytes = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let path = bytes > 0 ? String(cString: buffer) : ""
            let kernelName = withUnsafeBytes(of: info.pbsd.pbi_name) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let name = path.isEmpty ? (kernelName.isEmpty ? "PID \(pid)" : kernelName) : URL(fileURLWithPath: path).lastPathComponent
            readings.append(ProcessResourceReading(pid: pid, startSeconds: info.pbsd.pbi_start_tvsec,
                startMicroseconds: info.pbsd.pbi_start_tvusec, executablePath: path, name: name,
                cpuTicks: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system,
                residentBytes: info.ptinfo.pti_resident_size, sampledAt: DispatchTime.now().uptimeNanoseconds))
        }
        let warmingUp = previous.isEmpty
        let consumers = ProcessResourceMath.consumers(readings: readings, previous: previous,
                                                      processorCount: ProcessInfo.processInfo.activeProcessorCount,
                                                      nanosecondsPerTick: nanosecondsPerTick)
        previous = Dictionary(uniqueKeysWithValues: readings.map { ($0.identity, $0) })
        return ProcessResourceSample(consumers: consumers, unavailableProcessCount: unavailable,
                                     failed: readings.isEmpty, warmingUp: warmingUp)
    }
}

@MainActor
final class ProcessResourceMonitor: ObservableObject {
    @Published private(set) var consumers: [ProcessResourceConsumer] = []
    @Published private(set) var unavailableProcessCount = 0
    @Published private(set) var isWarmingUp = true
    @Published private(set) var isSampling = false
    @Published private(set) var samplingFailed = false
    private var samplingTask: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]

    func icon(for consumer: ProcessResourceConsumer) -> NSImage? {
        consumer.applicationPath.flatMap { icons[$0] }
    }

    func setActive(_ active: Bool) {
        guard active != isSampling else { return }
        isSampling = active
        samplingTask?.cancel()
        samplingTask = nil
        consumers = []
        icons.removeAll()
        names.removeAll()
        unavailableProcessCount = 0
        isWarmingUp = true
        samplingFailed = false
        guard active else { return }
        // Session-scoped sampler releases its counters when cancelled. A rapid
        // hide/show cannot reset the next session's baseline from an old task.
        let sampler = ProcessResourceSampler()
        samplingTask = Task { [weak self, sampler] in
            while !Task.isCancelled {
                let sample = await sampler.sample()
                guard !Task.isCancelled, self != nil else { return }
                self?.apply(sample)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private func apply(_ sample: ProcessResourceSample) {
        let runningNames = NSWorkspace.shared.runningApplications.reduce(into: [String: String]()) { result, app in
            if let path = app.bundleURL?.path, let name = app.localizedName { result[path] = name }
        }
        let activePaths = Set(sample.consumers.compactMap(\.applicationPath))
        icons = icons.filter { activePaths.contains($0.key) }
        names = names.filter { activePaths.contains($0.key) }
        consumers = sample.consumers.map { consumer in
            var consumer = consumer
            if let path = consumer.applicationPath {
                if icons[path] == nil { icons[path] = NSWorkspace.shared.icon(forFile: path) }
                if let name = runningNames[path] { names[path] = name }
                if names[path] == nil {
                    let displayName = FileManager.default.displayName(atPath: path)
                    names[path] = displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
                    // Keep the path-derived fallback if Finder has no localized name.
                    if names[path]?.isEmpty != false { names[path] = consumer.name }
                }
                consumer.name = names[path] ?? consumer.name
            }
            return consumer
        }
        unavailableProcessCount = sample.unavailableProcessCount
        samplingFailed = sample.failed
        isWarmingUp = sample.warmingUp
    }

    deinit { samplingTask?.cancel() }
}
