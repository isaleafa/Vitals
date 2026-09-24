import Darwin
import Foundation

/// CPU 原始计数器：Mach `host_processor_info`，每核 [user, system, idle, nice] 累计 tick。
enum CPUProvider {
    static func read() -> [[UInt32]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let user = Int(CPU_STATE_USER), system = Int(CPU_STATE_SYSTEM)
        let idle = Int(CPU_STATE_IDLE), nice = Int(CPU_STATE_NICE)
        var cores: [[UInt32]] = []
        cores.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            cores.append([
                UInt32(bitPattern: info[base + user]),
                UInt32(bitPattern: info[base + system]),
                UInt32(bitPattern: info[base + idle]),
                UInt32(bitPattern: info[base + nice]),
            ])
        }
        return cores
    }

    /// 两次采样取差 → 每核使用率（0…100）。tick 是 32 位，差值用 &- 处理回绕。
    static func usage(prev: [[UInt32]], cur: [[UInt32]]) -> [Double] {
        guard prev.count == cur.count else { return [] }
        return zip(prev, cur).map { a, b in
            let delta = (0..<4).map { UInt64(b[$0] &- a[$0]) }
            let total = delta.reduce(0, +)
            guard total > 0 else { return 0 }
            return 100.0 * Double(total - delta[2]) / Double(total)   // delta[2] = idle
        }
    }
}
