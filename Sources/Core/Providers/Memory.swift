import Darwin
import Foundation

struct MemoryRaw {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressor: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Int32 = 1
}

/// 内存：`host_statistics64`（原生版 vm_stat）+ `vm.swapusage` + 内存压力 sysctl。
enum MemoryProvider {
    static func read() -> MemoryRaw? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let page = Sysctl.pageSize()
        var raw = MemoryRaw()
        raw.total = Sysctl.totalMemoryBytes()
        raw.free = UInt64(stats.free_count) * page
        raw.active = UInt64(stats.active_count) * page
        raw.inactive = UInt64(stats.inactive_count) * page
        raw.wired = UInt64(stats.wire_count) * page
        raw.compressor = UInt64(stats.compressor_page_count) * page
        raw.swapUsed = Sysctl.swapUsedBytes()
        raw.pressure = Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1
        return raw
    }
}
