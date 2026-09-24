import Foundation

/// 一帧原始计数器（未做任何差分/换算，UI 不可见）。
struct RawCounters {
    var t = Date().timeIntervalSince1970
    var cpu: [[UInt32]]?
    var memory: MemoryRaw?
    var disk: DiskRaw?
    var diskCap: DiskCapacity?
    var net: [String: NetIfaceRaw] = [:]
    var power: PowerStats?

    static func collect() -> RawCounters {
        var r = RawCounters()
        r.t = Date().timeIntervalSince1970
        r.cpu = CPUProvider.read()
        r.memory = MemoryProvider.read()
        r.disk = DiskProvider.readCounters()
        r.diskCap = DiskProvider.capacity()
        r.net = NetworkProvider.read()
        r.power = PowerProvider.read()
        return r
    }
}
