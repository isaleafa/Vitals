import Foundation
import IOKit

struct DiskRaw {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var ops: UInt64 = 0
}

struct DiskCapacity {
    var total: UInt64 = 0
    var free: UInt64 = 0
}

/// 磁盘：IOKit `IOBlockStorageDriver` 累计计数器（速率靠差分）+ 容量（URLResourceValues）。
///
/// 性能要点：服务句柄只匹配一次并缓存，之后每秒只读 `Statistics` 这一个键——
/// 每次全量 `IORegistryEntryCreateCFProperties` 会把巨大的 IOReport 数据也建出来，很贵。
enum DiskProvider {
    private static var cachedService: io_object_t = 0

    static func readCounters() -> DiskRaw? {
        if cachedService == 0 {
            cachedService = findBusiestService()
            if cachedService == 0 { return nil }
        }
        guard let stats = IORegistryEntryCreateCFProperty(
            cachedService, "Statistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else {
            // 设备消失/句柄失效 → 下一次重新匹配
            IOObjectRelease(cachedService)
            cachedService = 0
            return nil
        }
        func num(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
        return DiskRaw(readBytes: num("Bytes (Read)"),
                       writeBytes: num("Bytes (Write)"),
                       ops: num("Operations (Read)") + num("Operations (Write)"))
    }

    /// 取"操作数最多"的块设备驱动 = 内置 SSD；返回已 retain 的句柄。
    private static func findBusiestService() -> io_object_t {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }

        var best: io_object_t = 0
        var bestOps: UInt64 = 0
        while true {
            let drive = IOIteratorNext(iter)
            guard drive != 0 else { break }
            guard let stats = IORegistryEntryCreateCFProperty(
                drive, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else {
                IOObjectRelease(drive)
                continue
            }
            func num(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            let ops = num("Operations (Read)") + num("Operations (Write)")
            if ops > bestOps {
                if best != 0 { IOObjectRelease(best) }
                best = drive
                bestOps = ops
            } else {
                IOObjectRelease(drive)
            }
        }
        return best
    }

    /// 容量走 C 的 `statfs`（微秒级）。注意别用 `URL.resourceValues`——
    /// 那会走 Foundation 的重路径，实测 16ms/次，是整个采样里最贵的一环。
    static func capacity() -> DiskCapacity? {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 else { return nil }
        let blockSize = UInt64(fs.f_bsize)
        return DiskCapacity(total: UInt64(fs.f_blocks) * blockSize,
                            free: UInt64(fs.f_bavail) * blockSize)
    }
}
