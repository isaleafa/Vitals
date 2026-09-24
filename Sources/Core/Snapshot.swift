import Foundation

/// 一帧完整快照。UI 只读这个，不接触任何原始计数器。
struct Snapshot: Codable {
    var time = Date()
    var cpu = CPUStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var net = NetStats()
    var power = PowerStats()
    var energy = EnergyStats()
    var thermal = ThermalStats()
}

/// 功耗明细（读不到的为空 = 界面显示"—"）
struct EnergyStats: Codable {
    var gpuWatts: Double?
    var cpuWatts: Double?
}

struct CPUStats: Codable {
    var total: Double = 0              // 0…100
    var perCore: [Double] = []
    var load: [Double] = [0, 0, 0]     // 1 / 5 / 15 分钟
    var uptime: TimeInterval = 0
}

struct MemoryStats: Codable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0          // active + wired + compressor（近似 Activity Monitor 口径）
    var availBytes: UInt64 = 0         // free + inactive
    var compressedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var pressure: Int = 1              // 1 正常 / 2 警告 / 4 严重

    var pressureText: String {
        switch pressure {
        case 2: return "警告"
        case 4: return "严重"
        default: return "正常"
        }
    }
}

struct DiskStats: Codable {
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var readBps: Double = 0
    var writeBps: Double = 0
    var iops: Double = 0
}

struct NetIface: Codable, Identifiable {
    var name: String
    var id: String { name }
    var up = false
    var addrs: [String] = []           // IP/CIDR
    var peer: String?                  // 点对点接口的对端地址（tunnel 常见）
    var mac: String?
    var mtu = 0
    var rxBps: Double = 0
    var txBps: Double = 0
    var rxTotal: UInt64 = 0
    var txTotal: UInt64 = 0
    /// 空闲 = 没有 IPv4 也没有实际流量（例如 macOS 常备的那些只有 fe80 的 utun）
    var idle = false
}

struct NetStats: Codable {
    var interfaces: [NetIface] = []      // 活跃接口（过滤后）
    var allInterfaces: [NetIface] = []   // 全部接口（页面可选显示，用来看清"空闲隧道"）
}

/// 电源页要的档位（PDO）：电压 mV / 电流 mA。
struct PowerGear: Codable, Identifiable {
    var index: Int
    var voltage: Int            // mV
    var current: Int            // mA
    var id: Int { index }

    var watts: Double { Double(voltage) * Double(current) / 1_000_000 }
    var text: String { String(format: "%g V / %.2f A", Double(voltage) / 1000, Double(current) / 1000) }
    var wattsText: String { String(format: "%g W", watts.rounded()) }
}

struct PowerStats: Codable {
    var charge = 0                     // %
    var charging = false
    var externalPower = false
    var inputVoltage = 0.0             // V（仅接电时有意义）
    var inputCurrent = 0.0             // mA
    var inputWatts = 0.0               // W：PowerTelemetryData.SystemPowerIn（接电时）
    var dischargeWatts = 0.0           // W：电池放电功率（电池供电时，取 |BatteryPower|）
    var batteryVoltage: Int?           // mV（电池侧）
    var batteryCurrent: Int?           // mA（放电为负）
    var adapterWatts: Int?
    var adapterVoltage: Int?           // mV
    var adapterCurrent: Int?           // mA
    var cycles: Int?

    /// 当前该显示哪个功率：接电看输入，电池供电看放电（拔电后 SystemPowerIn 会是 0，别拿它当"充电功率"）
    var effectiveWatts: Double { externalPower ? inputWatts : dischargeWatts }
    var powerLabel: String { externalPower ? "输入功率" : "放电功率" }

    // 电池健康（两个口径都留着，页面上并列显示并标注来源）
    var designCapacity: Int?           // mAh
    var fullChargeCapacity: Int?       // mAh
    var nominalCapacity: Int?          // mAh
    var healthRawPercent: Double?      // FullChargeCapacity / DesignCapacity
    var healthOfficialPercent: Int?    // system_profiler 口径
    var healthOfficialText: String?    // Good / Normal…

    // 适配器身份（USB-PD Discover Identity，来自端口 PD 节点）
    var adapterVID: Int?
    var adapterPID: Int?
    var pdRevision: Int?               // 3 → PD 3.0

    var gears: [PowerGear] = []        // 支持档位
    var activeGear: Int?               // 当前档位下标

    var vendorName: String? {          // 自建小库：VID → 厂商
        guard let vid = adapterVID else { return nil }
        return Self.vendorTable[vid]
    }

    static let vendorTable: [Int: String] = [
        0x2FE6: "Zhuhai iSmartWare（Anker 代工）",
        0x05E3: "Genesys Logic",
        0x291A: "Anker Innovations",
        0x05AC: "Apple Inc.",
    ]
}
