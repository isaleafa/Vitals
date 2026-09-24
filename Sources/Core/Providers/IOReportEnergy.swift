import Foundation
import CoreFoundation

/// 功耗明细（IOReport "Energy Model" 组，私有通道：Apple 没公开，但无需 root）。
///
/// ⚠️ 本机实测（M2 MacBook Air / macOS 27，2026-09-24）：
/// - `GPU Energy`（nJ）**可读**，每秒更新 ✓
/// - CPU / DRAM / ANE / DISP 等走 `AppleT8112PMGR` 的通道**恒为 0** ✗（不可读）
/// - IOReport 里的温度通道（GPU Stats/Temperature、TVPM、PMP）也全是 0 或 `Int64.min` ✗
/// - `IOHIDEventSystemClient`（macOS 27 之前读温度的标准私有路线）返回 0 个服务 ✗
/// 因此本 Provider 只报能读到的通道，读不到的返回 nil，界面据此显示"—"。
struct EnergyReading {
    var gpuWatts: Double?
    var cpuWatts: Double?
    var sampledAt = Date()
}

final class IOReportEnergy {
    static let shared = IOReportEnergy()

    private typealias CopyChannelsInGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<CFMutableDictionary?>?, UInt64, CFTypeRef?) -> CFDictionary?
    private typealias CreateSamples = @convention(c) (CFDictionary?, CFMutableDictionary?, CFTypeRef?) -> CFMutableDictionary?
    private typealias ChannelGetStr = @convention(c) (CFDictionary?, Int32) -> CFString?
    private typealias ChannelGetInt = @convention(c) (CFDictionary?, Int32) -> Int64

    private var copyChannels: CopyChannelsInGroup?
    private var createSub: CreateSubscription?
    private var createSamples: CreateSamples?
    private var chName: ChannelGetStr?
    private var chUnit: ChannelGetStr?
    private var simpleInt: ChannelGetInt?

    private var subscription: CFDictionary?
    private var channels: CFMutableDictionary?
    private var previous: [String: (value: Int64, unit: String, at: Date)] = [:]
    /// 连续多少次读到 0 就认定该通道不可用（本机 PMGR 的 CPU 通道就是这样）
    private var zeroStreak: [String: Int] = [:]
    private let zeroLimit = 3

    private init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        copyChannels = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self)
        createSub = symbol("IOReportCreateSubscription", CreateSubscription.self)
        createSamples = symbol("IOReportCreateSamples", CreateSamples.self)
        chName = symbol("IOReportChannelGetChannelName", ChannelGetStr.self)
        chUnit = symbol("IOReportChannelGetUnitLabel", ChannelGetStr.self)
        simpleInt = symbol("IOReportSimpleGetIntegerValue", ChannelGetInt.self)

        guard let copyChannels, let createSub,
              let group = copyChannels("Energy Model" as CFString, nil, 0, 0, 0) else { return }
        var subbed: CFMutableDictionary?
        subscription = createSub(nil, group, &subbed, 0, nil)
        channels = group
    }

    var isAvailable: Bool { subscription != nil }

    /// 取一次读数（内部与上一帧差分 → 瓦）。第一次调用返回 nil 值（没有基线）。
    func read() -> EnergyReading {
        guard let subscription, let channels, let createSamples,
              let chName, let chUnit, let simpleInt else {
            return EnergyReading(gpuWatts: nil, cpuWatts: nil)
        }
        guard let sample = createSamples(subscription, channels, nil),
              let dict = sample as? [String: Any],
              let list = dict["IOReportChannels"] as? [CFDictionary] else {
            return EnergyReading(gpuWatts: nil, cpuWatts: nil)
        }

        let now = Date()
        var current: [String: (value: Int64, unit: String, at: Date)] = [:]
        for channel in list {
            let name = (chName(channel, 0) as String?) ?? "?"
            let unit = (chUnit(channel, 0) as String?) ?? ""
            current[name] = (simpleInt(channel, 0), unit, now)
        }

        func watts(_ name: String) -> Double? {
            guard let now = current[name], let then = previous[name], now.value >= then.value else { return nil }
            let seconds = now.at.timeIntervalSince(then.at)
            guard seconds > 0.2 else { return nil }
            let delta = Double(now.value - then.value)
            let joules: Double
            switch now.unit {
            case "nJ": joules = delta / 1e9
            case "uJ": joules = delta / 1e6
            case "mJ": joules = delta / 1e3
            default: joules = delta
            }
            return joules / seconds
        }

        var reading = EnergyReading(gpuWatts: watts("GPU Energy"), cpuWatts: watts("CPU Energy"))
        // 连续为 0（或没有增量）的通道判定为"本机不可读"，返回 nil 而不是 0
        for (key, value) in [("GPU Energy", reading.gpuWatts), ("CPU Energy", reading.cpuWatts)] {
            if value == nil || value == 0 {
                zeroStreak[key, default: 0] += 1
                if zeroStreak[key, default: 0] >= zeroLimit {
                    if key == "GPU Energy" { reading.gpuWatts = nil } else { reading.cpuWatts = nil }
                }
            } else {
                zeroStreak[key] = 0
            }
        }
        previous = current
        return reading
    }
}
