import Foundation
import CoreFoundation
import IOKit

struct SensorReading: Codable, Identifiable {
    var name: String
    var celsius: Double
    var id: String { name }
}

/// 温度与功耗汇总（读不到的字段为 nil，界面显示"—"）
struct ThermalStats: Codable {
    var cpuTemp: Double?
    var gpuTemp: Double?
    var batteryTemp: Double?
    var nandTemp: Double?
    var systemWatts: Double?     // SMC `PSTR`：独立于电池遥测的系统功耗读数
    var sensors: [SensorReading] = []
}

/// 温度传感器：走 `IOHIDEventSystemClient`（私有通道，无需 root）。
///
/// 参考成熟实现 **macmon**（`src_lib/sources.rs` 的 `IOHIDSensors`）——2026-09-24 实测：
/// ✅ macOS 27 上这条路**是可用的**（本机读到 39 个传感器：`PMU tdie*` CPU 晶粒、`gas gauge battery` 电池、
/// `NAND CH0 temp` NAND…）。⚠️ 关键坑：遍历服务**必须** `CFArrayGetCount` + `CFArrayGetValueAtIndex`，
/// 用 Swift 的 `as? [UnsafeMutableRawPointer]` 强转 CFArray 会得到空数组 → 看起来像"系统不给服务"（我踩过）。
final class HIDSensors {
    static let shared = HIDSensors()

    private typealias CreateLegacy = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer?) -> CFArray?
    private typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer?, CFString?) -> CFTypeRef?
    private typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloat = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Double

    private var createClient: CreateLegacy?
    private var setMatching: SetMatching?
    private var copyServices: CopyServices?
    private var copyProperty: CopyProperty?
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?
    private var matching: CFDictionary?
    private var client: UnsafeMutableRawPointer?
    // 温度变化慢：2 秒缓存（本机 35 个传感器，每秒读一次多花 ~0.3% CPU）
    private var cached: ThermalStats?
    private var cachedAt = Date.distantPast
    private let cacheSeconds: TimeInterval = 2

    private init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        createClient = symbol("IOHIDEventSystemClientCreate", CreateLegacy.self)
        setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self)
        copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self)
        getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self)
        // AppleVendor(0xFF00) / TemperatureSensor(0x0005)：和 macmon 一致
        matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 0x0005] as CFDictionary
    }

    var isAvailable: Bool { createClient != nil && copyServices != nil }

    /// 读一次全部温度传感器（2 秒内重复调用直接返回缓存）。约几毫秒。
    func read() -> ThermalStats {
        if let cached, Date().timeIntervalSince(cachedAt) < cacheSeconds { return cached }
        let fresh = readUncached()
        cached = fresh
        cachedAt = Date()
        return fresh
    }

    private func readUncached() -> ThermalStats {
        guard let createClient, let setMatching, let copyServices,
              let copyProperty, let copyEvent, let getFloat, let matching else {
            return ThermalStats()
        }
        if client == nil {
            client = createClient(kCFAllocatorDefault)
            if let client { _ = setMatching(client, matching) }
        }
        guard let client, let services = copyServices(client) else { return ThermalStats() }

        var readings: [SensorReading] = []
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let event = copyEvent(service, 15 /* kIOHIDEventTypeTemperature */, 0, 0) else { continue }
            let celsius = getFloat(event, 15 << 16)
            guard celsius > 0, celsius <= 150 else { continue }   // 过滤无效值（和 macmon 同）
            let name = (copyProperty(service, "Product" as CFString) as? String) ?? "(无名)"
            readings.append(SensorReading(name: name, celsius: celsius))
        }
        readings.sort { $0.name < $1.name }

        func average(_ filter: (String) -> Bool) -> Double? {
            let values = readings.filter { filter($0.name) }.map(\.celsius)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        var stats = ThermalStats()
        // CPU 晶粒温度：PMU tdie* / PMU2 tdie*（本机的命名；M1 上叫 "*ACC MTR Temp Sensor"）
        stats.cpuTemp = average { name in
            (name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie"))
        } ?? average { $0.localizedCaseInsensitiveContains("MTR Temp Sensor") }
        stats.gpuTemp = average { $0.localizedCaseInsensitiveContains("GPU") || $0.hasPrefix("Tg") }
        stats.batteryTemp = average { $0.localizedCaseInsensitiveContains("gas gauge") }
        stats.nandTemp = average { $0.localizedCaseInsensitiveContains("NAND") }
        stats.sensors = readings

        // SMC 补位（macmon 的口径）：CPU = Tp*/Te*/Ts*、GPU = Tg*、系统功耗 = PSTR
        let smc = SMCReader.shared
        if smc.isAvailable {
            if let cpu = smc.averageTemperature(.cpu) { stats.cpuTemp = cpu }
            if let gpu = smc.averageTemperature(.gpu) { stats.gpuTemp = gpu }
            stats.systemWatts = smc.readFloat("PSTR")
        }
        return stats
    }
}
