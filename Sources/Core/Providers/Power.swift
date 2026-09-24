import Foundation
import IOKit

/// 电源：`AppleSmartBattery`（IORegistry）——输入 V/mA/mW、适配器、循环次数。
///
/// 性能要点：服务句柄缓存 + 只读需要的键（全量读属性会把 IOReportLegend 那种大块也建出来）。
enum PowerProvider {
    private static var cachedService: io_object_t = 0

    static func read() -> PowerStats? {
        if cachedService == 0 {
            cachedService = matchService()
            if cachedService == 0 { return nil }
        }
        guard let charge = number("CurrentCapacity") else {
            IOObjectRelease(cachedService)   // 句柄失效 → 下次重新匹配
            cachedService = 0
            return nil
        }

        var p = PowerStats()
        p.charge = charge.intValue
        p.charging = (number("IsCharging")?.boolValue) ?? false
        p.externalPower = (number("ExternalConnected")?.boolValue) ?? false
        p.cycles = number("CycleCount")?.intValue
        p.batteryVoltage = number("Voltage")?.intValue
        p.batteryCurrent = number("Amperage")?.intValue

        if let pt = dict("PowerTelemetryData") {
            func n(_ key: String) -> Double { (pt[key] as? NSNumber)?.doubleValue ?? 0 }
            p.inputVoltage = n("SystemVoltageIn") / 1000
            p.inputCurrent = n("SystemCurrentIn")
            p.inputWatts = n("SystemPowerIn") / 1000
            p.dischargeWatts = max(0, -n("BatteryPower")) / 1000   // BatteryPower 放电为负
        }
        if let ad = dict("AdapterDetails") {
            p.adapterWatts = (ad["Watts"] as? NSNumber)?.intValue
            p.adapterVoltage = (ad["AdapterVoltage"] as? NSNumber)?.intValue
            p.adapterCurrent = (ad["Current"] as? NSNumber)?.intValue
            // 支持档位（PDO 列表）：当前档位由 UsbHvcHvcIndex 指认
            if let menu = ad["UsbHvcMenu"] as? [[String: Any]] {
                p.gears = menu.enumerated().compactMap { index, gear in
                    guard let voltage = (gear["MaxVoltage"] as? NSNumber)?.intValue, voltage > 0,
                          let current = (gear["MaxCurrent"] as? NSNumber)?.intValue, current > 0 else { return nil }
                    return PowerGear(index: index, voltage: voltage, current: current)
                }
            }
            p.activeGear = (ad["UsbHvcHvcIndex"] as? NSNumber)?.intValue
        }
        // 电池健康：原始口径（容量比）；官方口径在 officialHealth() 里另外读
        if let battery = dict("BatteryData") {
            p.designCapacity = (battery["DesignCapacity"] as? NSNumber)?.intValue
            p.fullChargeCapacity = (battery["FullChargeCapacity"] as? NSNumber)?.intValue
            p.nominalCapacity = (battery["NominalChargeCapacity"] as? NSNumber)?.intValue
            if let design = p.designCapacity, design > 0, let full = p.fullChargeCapacity {
                p.healthRawPercent = Double(full) / Double(design) * 100
            }
        }
        return p
    }

    /// 官方口径健康度：`system_profiler -json SPPowerDataType`（约 0.3~1 秒，低频调用）。
    static func officialHealth() -> (percent: Int?, text: String?)? {
        guard let path = Shell.which("system_profiler") else { return nil }
        let output = Shell.run(path, ["-json", "SPPowerDataType"], timeout: 8)
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let percentText = health["sppower_battery_health_maximum_capacity"] as? String   // "93%"
            let percent = percentText.flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            return (percent, health["sppower_battery_health"] as? String)
        }
        return nil
    }

    // MARK: - 缓存句柄上的单键读取

    private static func matchService() -> io_object_t {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSmartBattery"),
                                           &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }
        return IOIteratorNext(iter)   // 0 表示没匹配到
    }

    private static func number(_ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(cachedService, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }

    private static func dict(_ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(cachedService, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
