import AppKit
import SwiftUI

/// Vitals — Mac 菜单栏工具箱 + 实时监视器
/// 菜单栏常驻：电池图标（默认显示电源，可以替掉系统自带的电池项）；点开是总览面板。
@main
struct VitalsApp: App {
    @StateObject private var state = AppState.shared
    private let sampler: Sampler
    private let previewMode = CommandLine.arguments.contains("--preview")

    init() {
        // 命令行核对模式：`Vitals --dump` 打印一帧 JSON 后退出（用于和 probes/ 对账）
        if CommandLine.arguments.contains("--dump") {
            DumpMode.run()
            exit(0)
        }
        // 性能自测：`Vitals --bench [次数]`
        if let index = CommandLine.arguments.firstIndex(of: "--bench") {
            let count = CommandLine.arguments.count > index + 1
                ? (Int(CommandLine.arguments[index + 1]) ?? 50) : 50
            DumpMode.bench(iterations: count)
            exit(0)
        }
        sampler = Sampler(state: AppState.shared)
        sampler.start()
        AppState.shared.refreshLoginItem()
        // 打开网络页就自动跑一次体检（不用手点）
        AppState.shared.onDetailPageOpened = { page in
            if page == "net" {
                AppState.shared.runNetworkChecks?()
                AppState.shared.probeSSHHosts?()
            }
            if page == "services" { AppState.shared.refreshLaunchItems?() }
        }

        // 告警演示：`--alert-demo` 把阈值降到必触发，便于截图核对告警样式（只影响本进程）
        if CommandLine.arguments.contains("--alert-demo") {
            AppState.shared.cpuHighPercent = 0.1
            AppState.shared.cpuSustainedSeconds = 2
            AppState.shared.diskFreeFloor = 0.99
        }

        // 阈值告警（命令行）：`Vitals --alerts`（只评估瞬时条件；CPU 持续类需要运行中采样）
        if CommandLine.arguments.contains("--alerts") {
            let state = AppState.shared
            _ = RawCounters.collect()
            Thread.sleep(forTimeInterval: 1.0)
            let snapshot = DiffEngine.snapshot(prev: RawCounters.collect(), cur: RawCounters.collect())
            print("瞬时条件评估:")
            print("  内存压力 = \(snapshot.memory.pressureText)（阈值：严重才报）")
            let free = snapshot.disk.totalBytes > 0
                ? Double(snapshot.disk.freeBytes) / Double(snapshot.disk.totalBytes) * 100 : 0
            print(String(format: "  磁盘可用 = %.1f%%（阈值：< %.0f%%）", free, state.diskFreeFloor * 100))
            print("  CPU 当前 = \(String(format: "%.1f%%", snapshot.cpu.total))（阈值：持续 ≥ \(Int(state.cpuHighPercent))% 满 \(state.cpuSustainedSeconds) 秒）")
            print("  健康度降幅告警需历史跨度 ≥ 5 天，当前: \(state.healthAlert ?? "未触发")")
            exit(0)
        }

        // 登录项 / 后台服务（命令行）：`Vitals --launch-items`
        if CommandLine.arguments.contains("--launch-items") {
            let items = LaunchItemsProvider.read()
            print("登录项 / 后台服务（\(items.count) 项）:")
            for item in items {
                let state = item.running ? "运行中" : "未运行"
                let enabled = item.enabled == false ? "已禁用" : "启用"
                print("  [\(item.kind.rawValue)] \(item.name) (\(item.identifier)) · \(state) · \(enabled)"
                      + (item.program.map { " · \($0)" } ?? "")
                      + (item.note.map { "  ⚠️ \($0)" } ?? ""))
            }
            exit(0)
        }

        // SMC 温度（命令行）：`Vitals --smc`（对照 macmon 的口径）
        if CommandLine.arguments.contains("--smc") {
            let smc = SMCReader.shared
            guard smc.isAvailable else { print("SMC 打不开（AppleSMCKeysEndpoint 未找到或打开失败）"); exit(1) }
            var cache: [String: [String]] = [:]
            let keys = smc.temperatureKeys(cache: &cache)
            func printKeys(_ label: String, _ list: [String]) {
                print("\(label)（\(list.count) 个键）:")
                for key in list {
                    let value = smc.readFloat(key)
                    print(String(format: "  %@  %@ °C", key, value.map { String(format: "%.2f", $0) } ?? "—"))
                }
            }
            printKeys("CPU", keys.cpu)
            printKeys("GPU", keys.gpu)
            print("风扇键: \(keys.fans.isEmpty ? "无（Apple Silicon Air 无风扇）" : keys.fans.joined(separator: ", "))")
            let cpuValues = keys.cpu.compactMap { smc.readFloat($0) }.filter { $0 > 0 && $0 < 150 }
            let gpuValues = keys.gpu.compactMap { smc.readFloat($0) }.filter { $0 > 0 && $0 < 150 }
            if !cpuValues.isEmpty {
                print(String(format: "→ CPU 平均 %.1f °C", cpuValues.reduce(0, +) / Double(cpuValues.count)))
            }
            if !gpuValues.isEmpty {
                print(String(format: "→ GPU 平均 %.1f °C", gpuValues.reduce(0, +) / Double(gpuValues.count)))
            }
            exit(0)
        }

        // 温度传感器（命令行）：`Vitals --sensors`
        if CommandLine.arguments.contains("--sensors") {
            let thermal = HIDSensors.shared.read()
            func text(_ value: Double?) -> String {
                value.map { String(format: "%.1f °C", $0) } ?? "—"
            }
            print("归类: CPU \(text(thermal.cpuTemp)) | GPU \(text(thermal.gpuTemp)) | 电池 \(text(thermal.batteryTemp)) | NAND \(text(thermal.nandTemp))")
            print("全部传感器（\(thermal.sensors.count) 个）:")
            for sensor in thermal.sensors {
                print(String(format: "  %-38s %.2f °C", (sensor.name as NSString).utf8String!, sensor.celsius))
            }
            exit(0)
        }

        // 功耗明细（命令行）：`Vitals --energy`
        if CommandLine.arguments.contains("--energy") {
            _ = IOReportEnergy.shared.read()          // 建立基线
            Thread.sleep(forTimeInterval: 1.0)
            let reading = IOReportEnergy.shared.read()
            print("功耗（IOReport）:")
            print("  GPU: \(reading.gpuWatts.map { String(format: "%.2f W", $0) } ?? "不可读")")
            print("  CPU: \(reading.cpuWatts.map { String(format: "%.2f W", $0) } ?? "不可读")")
            exit(0)
        }

        // SSH 主机探测（命令行）：`Vitals --ssh`
        if CommandLine.arguments.contains("--ssh") {
            let hosts = SSHHostsProvider.parse()
            print("SSH 主机（\(hosts.count) 台，来自 ~/.ssh/config）:")
            for host in hosts {
                let (ok, ms) = SSHHostsProvider.probe(host)
                let symbol = ok ? "✅" : "❌"
                let latency = ms.map { String(format: "%.0f ms", $0) } ?? "不通"
                let note = host.note.map { "  // \($0)" } ?? ""
                print("  \(symbol) " + host.alias.padding(toLength: 16, withPad: " ", startingAt: 0)
                      + host.target.padding(toLength: 26, withPad: " ", startingAt: 0) + latency + note)
            }
            exit(0)
        }

        // 监听端口清单（命令行）：`Vitals --ports`
        if CommandLine.arguments.contains("--ports") {
            print("监听端口（自建在前）:")
            for service in ListeningPortsProvider.read() {
                let tag = service.custom ? "[自建]" : "[系统]"
                let note = service.note.map { "  // \($0)" } ?? ""
                print("  \(tag) \(service.command)(\(service.pid)) : \(service.portsText)\(note)")
            }
            exit(0)
        }

        // 网络体检（命令行）：`Vitals --check-network`
        if CommandLine.arguments.contains("--check-network") {
            let proxy = ProxyProvider.read().http
            print("网络体检（proxy=\(proxy ?? "未启用")）:")
            for item in NetworkCheckProvider.items() {
                let result = NetworkCheckProvider.run(item.id, proxy: proxy)
                let symbol = result.status == .ok ? "✅" : (result.status == .skipped ? "－" : "❌")
                print("  " + item.title.padding(toLength: 20, withPad: " ", startingAt: 0) + symbol + " " + result.summary)
            }
            exit(0)
        }

        // 命令行开关自启：`Vitals --login-item on|off`（打印结果，便于核对）
        if let index = CommandLine.arguments.firstIndex(of: "--login-item"),
           CommandLine.arguments.count > index + 1 {
            let wanted = CommandLine.arguments[index + 1] == "on"
            let result = LoginItem.setEnabled(wanted)
            print("login item enabled=\(result.enabled) message=\(result.message ?? "-")")
            exit(0)
        }

        // 调试：`--period hour|day|week` 指定历史周期（配合 --preview 逐档核对曲线）
        if let index = CommandLine.arguments.firstIndex(of: "--period"),
           CommandLine.arguments.count > index + 1 {
            switch CommandLine.arguments[index + 1] {
            case "hour": AppState.shared.historyPeriod = .hour
            case "week": AppState.shared.historyPeriod = .week
            case "month": AppState.shared.historyPeriod = .month
            default: AppState.shared.historyPeriod = .day
            }
        }

        // 预览模式：`Vitals --preview [cpu|mem|disk|net|power] [--idle]` 开一个固定位置的窗口（便于截图/调 UI）
        if previewMode {
            UserDefaults.standard.set(CommandLine.arguments.contains("--idle"), forKey: "PreviewShowIdle")
            let page = CommandLine.arguments.drop(while: { $0 != "--preview" }).dropFirst().first ?? "overview"
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                VitalsApp.previewWindow = Self.makePreviewWindow(page: page)
                NSApplication.shared.activate(ignoringOtherApps: true)
                // 预览开关只对这次预览有效，别影响正式页面
                UserDefaults.standard.set(false, forKey: "PreviewShowIdle")
                // `--run-checks`：预览时顺手跑一次网络体检（便于核对结果渲染）
                if CommandLine.arguments.contains("--run-checks") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        AppState.shared.runNetworkChecks?()
                    }
                }
            }
        }

        // 直接开某个详情窗口：`Vitals --open net`（和点卡片走同一条路径，便于核对窗口位置）
        if let index = CommandLine.arguments.firstIndex(of: "--open"),
           CommandLine.arguments.count > index + 1 {
            let page = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                DetailWindows.open(page, state: AppState.shared)
            }
        }
    }

    /// 静态持有，否则窗口会被 ARC 释放
    private static var previewWindow: NSWindow?

    private static func makePreviewWindow(page: String) -> NSWindow {
        let size = DetailWindows.size(of: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Vitals 预览 · \(page)"
        window.contentView = NSHostingView(rootView: DetailWindows.view(of: page, state: .shared))
        // 固定钉在主屏左上角（便于截图核对；center() 在多屏下不可预期）
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + 80, y: screen.frame.maxY - 80))
        }
        window.makeKeyAndOrderFront(nil)
        // 打出窗口号：外层可以用 `screencapture -l <号>` 截图，不受窗口前后层级影响
        print("preview window id = \(window.windowNumber)")
        fflush(stdout)
        return window
    }

    var body: some Scene {
        MenuBarExtra {
            OverviewPanel(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
        // 详情窗口交给 DetailWindows 用 AppKit 管（SwiftUI 的 Window 场景不给控制位置，也不保证提到最前）
    }
}

/// 菜单栏常驻标签：只显示电源图标（电池分档 + 接电带闪电），不显示百分比——
/// 百分比在点开后（总览卡片 / 电源页）看。
///
/// 图标是自绘的模板图（`MenuBarBatteryIcon`）：SwiftUI 会把 `Image(systemName:)` 还原成符号名
/// 交给 AppKit 按默认尺寸画，`.font()`/`.frame()` 那些修饰全被丢掉——自绘才能"变大但占位不变"。
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        // ⚠️ 必须保持"单个 Image"的形状：写 if 分支（ViewBuilder 的 _ConditionalContent）
        // 会让整个菜单栏图标渲染不出来（2026-09-24 实测）。所以只在两张图之间切换。
        Image(nsImage: state.allAlerts.isEmpty
              ? MenuBarBatteryIcon.image(charge: state.snapshot.power.charge,
                                         plugged: state.snapshot.power.externalPower)
              : MenuBarBatteryIcon.warning)
    }
}
