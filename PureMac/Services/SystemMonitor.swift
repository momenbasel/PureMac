import Foundation
import Darwin

/// Lightweight live system telemetry for the menu-bar monitor (CPU / memory /
/// disk). Each visible consumer owns a sampling request. The fastest request
/// determines the interval; releasing the last request stops sampling. The
/// enabled menu-bar monitor can continue independently of the Performance page.
///
/// All readings use public Mach / Foundation APIs (no sandbox-incompatible
/// shelling out), so this stays valid under the app's hardened-runtime,
/// notarized build.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    /// 0.0 - 1.0 fraction of total CPU time spent non-idle since the last sample.
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsed: Int64 = 0
    @Published private(set) var memoryTotal: Int64 = 0
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0

    var memoryFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal)
    }

    var diskFraction: Double {
        guard diskTotal > 0 else { return 0 }
        return Double(diskUsed) / Double(diskTotal)
    }

    private var timer: Timer?
    /// Previous CPU tick counters, kept to turn the kernel's monotonically
    /// increasing totals into a per-interval delta.
    private var previousBusy: UInt64 = 0
    private var previousTotal: UInt64 = 0
    // Idempotent subscriptions prevent repeated view activation from leaking a
    // timer. Each consumer releases only its own request.
    private var requests: [UUID: TimeInterval] = [:]
    private var timerGeneration = UUID()
    private let sampleAction: (() -> Void)?
    private(set) var samplingInterval: TimeInterval?
    var isSampling: Bool { timer != nil }

    init(sampleAction: (() -> Void)? = nil) {
        self.sampleAction = sampleAction
    }

    func start(owner: UUID, interval: TimeInterval = 2.0) {
        requests[owner] = interval.isFinite ? max(0.1, interval) : 2
        configureTimer()
    }

    func stop(owner: UUID) {
        requests.removeValue(forKey: owner)
        configureTimer()
    }

    private func configureTimer() {
        let interval = requests.values.min()
        guard interval != samplingInterval else { return }
        let wasStopped = timer == nil
        timer?.invalidate()
        timer = nil
        timerGeneration = UUID()
        samplingInterval = interval
        guard let interval else {
            previousBusy = 0
            previousTotal = 0
            return
        }
        if wasStopped {
            memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
            cpuUsage = 0
            sample()
        }
        let generation = timerGeneration
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timerGeneration == generation, !self.requests.isEmpty else { return }
                self.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        if let sampleAction {
            sampleAction()
        } else {
            sampleCPU()
            sampleMemory()
            sampleDisk()
        }
    }

    deinit { timer?.invalidate() }

    // MARK: - CPU

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        let total = busy &+ idle

        defer { previousBusy = busy; previousTotal = total }
        // First sample has no prior baseline to diff against.
        guard previousTotal != 0, total > previousTotal else { return }

        let busyDelta = Double(busy &- previousBusy)
        let totalDelta = Double(total &- previousTotal)
        guard totalDelta > 0 else { return }
        cpuUsage = min(1, max(0, busyDelta / totalDelta))
    }

    // MARK: - Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = Int64(vm_kernel_page_size)
        // "App Memory" + wired + compressed mirrors what Activity Monitor counts
        // as memory pressure; free + purgeable + most file-backed pages are not
        // pressure, so they're excluded.
        let used = (Int64(stats.active_count)
            + Int64(stats.wire_count)
            + Int64(stats.compressor_page_count)) * pageSize
        memoryUsed = used
    }

    // MARK: - Disk

    private func sampleDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return }

        if let total = values.volumeTotalCapacity {
            diskTotal = Int64(total)
        }
        if let available = values.volumeAvailableCapacityForImportantUsage {
            diskUsed = max(0, diskTotal - available)
        }
    }
}
