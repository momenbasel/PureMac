import Foundation
import Darwin

enum SystemInfo {

    static func memory() -> (free: Int64, inactive: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let page = Int64(vm_kernel_page_size)
        return (Int64(stats.free_count) * page, Int64(stats.inactive_count) * page)
    }

    static func volume(_ path: String) -> (available: Int64, total: Int64) {
        let url = URL(fileURLWithPath: path)
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let avail = Int64(vals?.volumeAvailableCapacityForImportantUsage ?? Int64(vals?.volumeAvailableCapacity ?? 0))
        let total = Int64(vals?.volumeTotalCapacity ?? 0)
        return (avail, total)
    }
}
