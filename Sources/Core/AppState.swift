import AppKit
import Combine
import Foundation

/// UI 唯一的数据来源：最新快照 + 各指标的 60 点历史（喂迷你曲线）+ 详情页按需采样的数据。
///
/// 说明：这里用 Combine 的 `ObservableObject` 而不是 `@Observable`——
/// 本机只有 Command Line Tools，工具链里没有 SwiftUIMacros 插件，`@State` 编译不过；
/// 而 `ObservableObject` / `@Published` / `@ObservedObject` / `@StateObject` 都是普通类型，能正常编。
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var snapshot = Snapshot()

    /// 菜单栏常驻：默认显示**电源**（电池图标 + 电量%，接电源时带闪电）。
    /// 这样可以把系统自带的电池项收起来，用我们自己的。
    @Published var menuBarSymbol = "battery.100"
    @Published var menuBarText = "…"

    // 60 点迷你曲线（1 秒一个点）
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []          // 已用 GB
    @Published var diskHistory: [Double] = []         // 读+写 MB/s
    @Published var diskReadHistory: [Double] = []
    @Published var diskWriteHistory: [Double] = []
    @Published var netHistory: [Double] = []          // 全接口 下行+上行 KB/s
    @Published var powerHistory: [Double] = []        // 当前口径的功率（接电=输入 / 电池=放电）
    @Published var inputPowerHistory: [Double] = []   // 输入功率（插电时非零）
    @Published var dischargePowerHistory: [Double] = []  // 放电功率（拔电时非零）

    // 详情页按需采样：页面打开才置位，关掉就停（避免常态开销）
    @Published var wantRoutes = false
    @Published var wantProcesses = false
    @Published var wantSmart = false

    @Published var routes: [RouteEntry] = []
    @Published var routes6: [RouteEntry] = []
    @Published var defaultRouteIface: String?
    @Published var proxy = ProxyInfo()          // 系统代理（Clash 这类工具走这里，不建隧道）
    @Published var processesByCPU: [ProcInfo] = []
    @Published var processesByMemory: [ProcInfo] = []
    @Published var smart: [(label: String, value: String)] = []   // SSD 健康（中文标签，顺序固定）

    /// 由 Sampler 注入：网络页一打开就立刻采一次（不用等下一个 tick）
    var onNetworkPageOpened: (() -> Void)?

    /// 阈值告警（轻量）：只对真异常报——CPU 持续过高、内存压力=严重、磁盘可用过低、电池健康明显下降。
    /// 本机内存常年在"警告"档，所以内存**只在"严重"**才报（否则天天响 = 噪音）。
    @Published var alerts: [String] = []
    @Published var healthAlert: String?
    private var sustainedHighCPU = 0
    var cpuHighPercent = 90.0
    var cpuSustainedSeconds = 30
    var diskFreeFloor = 0.08

    var allAlerts: [String] { alerts + [healthAlert].compactMap { $0 } }

    private func evaluateAlerts(_ s: Snapshot) {
        var next: [String] = []
        // CPU 持续 >90%（连续 30 秒）
        if s.cpu.total >= cpuHighPercent {
            sustainedHighCPU += 1
        } else {
            sustainedHighCPU = 0
        }
        if sustainedHighCPU >= cpuSustainedSeconds {
            next.append("CPU 持续高于 \(Int(cpuHighPercent))%（\(sustainedHighCPU) 秒）")
        }
        // 内存压力 = 严重(4)
        if s.memory.pressure >= 4 {
            next.append("内存压力：严重")
        }
        // 磁盘可用 < 8%
        if s.disk.totalBytes > 0 {
            let free = Double(s.disk.freeBytes) / Double(s.disk.totalBytes)
            if free < diskFreeFloor {
                next.append(String(format: "磁盘可用仅 %.1f%%", free * 100))
            }
        }
        if next != alerts { alerts = next }
    }

    /// 登录项 / 后台服务审计（服务页打开时扫一次）
    @Published var launchItems: [LaunchItem] = []
    var refreshLaunchItems: (() -> Void)?

    /// 监听端口 / 自建服务（网络页打开时低频刷新）
    @Published var services: [ListeningService] = []

    /// 详情页打开时的回调（由 DetailWindows 触发；页面 onAppear 在窗口复用时不一定再触发）
    var onDetailPageOpened: ((String) -> Void)?

    /// SSH 主机可达性（~/.ssh/config，网络页打开时自动并发探测）
    @Published var sshHosts: [SSHHostProbe] = []
    @Published var sshProbing = false
    var probeSSHHosts: (() -> Void)?

    /// 网络一键体检（结果逐条回填）
    @Published var checks: [NetworkCheckResult] = []
    @Published var checksRunning = false
    var runNetworkChecks: (() -> Void)?

    /// 开机自启（SMAppService，失败退回 LaunchAgent）
    @Published var loginItemEnabled = false
    @Published var loginItemMessage: String?

    func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
    }

    func setLoginItem(_ enabled: Bool) {
        let result = LoginItem.setEnabled(enabled)
        loginItemEnabled = result.enabled
        loginItemMessage = result.message
    }

    @Published var samplesTaken = 0

    /// 历史曲线：周期（页面共用）+ 聚合好的序列（后台算，见 Sampler.refreshHistory）
    @Published var historyPeriod: HistoryPeriod = .day {
        didSet { onHistoryReloadNeeded?() }
    }
    @Published var historyBundle = HistoryBundle()
    var onHistoryReloadNeeded: (() -> Void)?

    let historyLimit = 60

    /// 只在主线程调用（Sampler 的 Timer 就在主线程）。
    func apply(_ s: Snapshot) {
        snapshot = s
        samplesTaken += 1

        cpuHistory = pushed(cpuHistory, s.cpu.total)
        memHistory = pushed(memHistory, Double(s.memory.usedBytes) / 1_073_741_824)
        diskHistory = pushed(diskHistory, (s.disk.readBps + s.disk.writeBps) / 1_048_576)
        diskReadHistory = pushed(diskReadHistory, s.disk.readBps / 1_048_576)
        diskWriteHistory = pushed(diskWriteHistory, s.disk.writeBps / 1_048_576)
        netHistory = pushed(netHistory, s.net.interfaces.reduce(0) { $0 + $1.rxBps + $1.txBps } / 1024)
        powerHistory = pushed(powerHistory, s.power.effectiveWatts)   // 接电=输入功率，电池=放电功率
        inputPowerHistory = pushed(inputPowerHistory, s.power.inputWatts)
        dischargePowerHistory = pushed(dischargePowerHistory, s.power.dischargeWatts)

        evaluateAlerts(s)

        menuBarSymbol = Self.batterySymbol(charge: s.power.charge, powered: s.power.externalPower)
        menuBarText = "\(s.power.charge)%"   // 仅备查：菜单栏现在只显示图标，不显示百分比
    }

    /// 返回新数组再整体赋值，保证 @Published 一定发出通知（原地 append 可能不触发）。
    private func pushed(_ array: [Double], _ value: Double) -> [Double] {
        var next = array
        next.append(value)
        if next.count > historyLimit { next.removeFirst(next.count - historyLimit) }
        return next
    }

    /// 电池 SF Symbol：电量分档 + 接电源时带闪电（符号不存在就退回无闪电版本）。
    static func batterySymbol(charge: Int, powered: Bool) -> String {
        let level = charge >= 100 ? "100" : charge >= 75 ? "75" : charge >= 50 ? "50" : charge >= 25 ? "25" : "0"
        if powered {
            let bolted = "battery.\(level).bolt"
            if NSImage(systemSymbolName: bolted, accessibilityDescription: nil) != nil { return bolted }
        }
        return "battery.\(level)"
    }
}
