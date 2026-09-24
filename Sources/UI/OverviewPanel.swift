import AppKit
import SwiftUI

/// 总览页：五张指标卡（CPU / 内存 / 磁盘 / 网络 / 电源），每张 = 主数值 + 副信息 + 60 秒迷你曲线。
/// 点卡片打开对应详情窗口（居中、提到最前，见 DetailWindows）。
struct OverviewPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if !state.allAlerts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.allAlerts, id: \.self) { alert in
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.red)
                            Text(alert).font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.10)))
            }

            card("cpu") {
                MetricCard(title: "CPU", icon: "cpu",
                           value: Fmt.pct0(state.snapshot.cpu.total),
                           detail: "负载 \(loadText) · \(state.snapshot.cpu.perCore.count) 核",
                           color: state.alerts.contains { $0.hasPrefix("CPU") } ? .red : .blue,
                           history: state.cpuHistory)
            }

            card("mem") {
                MetricCard(title: "内存", icon: "memorychip",
                           value: "\(Fmt.gb(state.snapshot.memory.usedBytes)) / \(Fmt.gb(state.snapshot.memory.totalBytes)) GB",
                           detail: "\(state.snapshot.memory.pressureText) · 压缩 \(Fmt.gb(state.snapshot.memory.compressedBytes))G · 交换 \(state.snapshot.memory.swapUsedBytes / 1_048_576)M",
                           color: memoryColor, history: state.memHistory)
            }

            card("disk") {
                MetricCard(title: "存储", icon: "internaldrive",
                           value: "\(Fmt.bytes(usedDisk)) / \(Fmt.bytes(state.snapshot.disk.totalBytes))",
                           detail: "读 \(Fmt.rate(state.snapshot.disk.readBps)) · 写 \(Fmt.rate(state.snapshot.disk.writeBps)) · \(Int(state.snapshot.disk.iops)) IOPS",
                           color: state.alerts.contains { $0.hasPrefix("磁盘") } ? .red : .green,
                           history: state.diskHistory)
            }

            card("net") {
                MetricCard(title: "网络", icon: "network",
                           value: "↓\(Fmt.rate(rxRate)) ↑\(Fmt.rate(txRate))",
                           detail: netDetail,
                           color: .purple, history: state.netHistory)
            }

            card("power") {
                MetricCard(title: "电源 · Pulse", icon: state.menuBarSymbol,
                           value: String(format: "%.1f W", state.snapshot.power.effectiveWatts),
                           detail: powerDetail,
                           color: powerColor, history: state.powerHistory)
            }

            HStack(spacing: 8) {
                Button("服务与自启 →") { DetailWindows.open("services", state: state) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                Toggle("开机自启", isOn: Binding(get: { state.loginItemEnabled },
                                              set: { state.setLoginItem($0) }))
                    .toggleStyle(.switch)
                    .font(.system(size: 10))
                if let message = state.loginItemMessage {
                    Text(message).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer()
            }

            footer
        }
        .padding(12)
        .frame(width: 330)
    }

    /// 整张卡片当按钮：点开对应详情窗口（自己管窗口：居中 + 提到最前）。
    private func card<Content: View>(_ page: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            DetailWindows.open(page, state: state)
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .help("查看详情")
    }

    // MARK: - 小计算

    private var loadText: String {
        state.snapshot.cpu.load.map { String(format: "%.1f", $0) }.joined(separator: "/")
    }

    private var usedDisk: UInt64 {
        let d = state.snapshot.disk
        return d.totalBytes > d.freeBytes ? d.totalBytes - d.freeBytes : 0
    }

    private var memoryColor: Color {
        switch state.snapshot.memory.pressure {
        case 2: return .yellow
        case 4: return .red
        default: return .teal
        }
    }

    /// 接电=橙色（输入功率），电池=紫色（放电功率）——颜色本身就是模式标识
    private var powerColor: Color {
        state.snapshot.power.externalPower ? .orange : .purple
    }

    private var rxRate: Double { state.snapshot.net.interfaces.reduce(0) { $0 + $1.rxBps } }
    private var txRate: Double { state.snapshot.net.interfaces.reduce(0) { $0 + $1.txBps } }

    private var netDetail: String {
        let names = state.snapshot.net.interfaces.prefix(3).map(\.name)
        return names.isEmpty ? "无活跃接口" : names.joined(separator: " · ")
    }

    private var powerDetail: String {
        let p = state.snapshot.power
        var parts = [p.powerLabel, "\(p.charge)%", p.externalPower ? "已接通" : "电池供电"]
        if p.charging { parts.append("充电中") }
        if let w = p.adapterWatts { parts.append("适配器 \(w)W") }
        if let c = p.cycles { parts.append("循环 \(c)") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge").font(.system(size: 11)).foregroundStyle(.blue)
            Text("Vitals").font(.system(size: 12, weight: .semibold))
            Text("Mac 工具箱 · 实时监视").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text("运行 \(Fmt.duration(state.snapshot.cpu.uptime))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("更新于 \(Self.timeText.string(from: state.snapshot.time))")
                .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
            Text("点卡片看详情").font(.system(size: 10)).foregroundStyle(.tertiary)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 1)
    }

    private static let timeText: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 单张指标卡：标题行 + （大数值｜迷你曲线）。
struct MetricCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let color: Color
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Sparkline(values: history, color: color)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
        )
    }
}
