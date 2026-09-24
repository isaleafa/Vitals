import SwiftUI

/// CPU 详情页：总量 + 分核（性能核/能效核分组着色）+ 进程 TOP。
struct CPUPage: View {
    @ObservedObject var state: AppState

    private var snapshot: Snapshot { state.snapshot }
    private var perfCores: Int { Int(Sysctl.uint64("hw.perflevel0.logicalcpu") ?? 0) }

    var body: some View {
        PageShell(state: state,
                  title: "CPU",
                  subtitle: "\(snapshot.cpu.perCore.count) 核 · 已运行 \(Fmt.duration(snapshot.cpu.uptime))",
                  want: { $0.wantProcesses = true },
                  unwant: { $0.wantProcesses = false }) {
            SectionBox(title: "总览") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.pct0(snapshot.cpu.total))
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("负载 " + loadText).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(perfCores) 性能核 + \(max(0, snapshot.cpu.perCore.count - perfCores)) 能效核")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                Sparkline(values: state.cpuHistory, color: .blue).frame(height: 42)
            }

            SectionBox(title: "分核占用") {
                VStack(spacing: 4) {
                    ForEach(Array(snapshot.cpu.perCore.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 6) {
                            Text("核\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(index < perfCores ? .primary : .secondary)
                                .frame(width: 28, alignment: .leading)
                            MetricBar(fraction: value / 100, color: index < perfCores ? .blue : .teal)
                            Text(String(format: "%3.0f%%", value))
                                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }

            SectionBox(title: "温度与功耗") {
                let power = state.snapshot.power
                let energy = state.snapshot.energy
                let thermal = state.snapshot.thermal
                InfoRow(label: "CPU 温度", value: Self.tempText(thermal.cpuTemp), color: .pink)
                InfoRow(label: "GPU 温度", value: Self.tempText(thermal.gpuTemp))
                InfoRow(label: "系统功耗（\(power.powerLabel)）",
                        value: String(format: "%.1f W", power.effectiveWatts), color: .orange)
                InfoRow(label: "SoC 功耗（SMC PSTR）",
                        value: thermal.systemWatts.map { String(format: "%.2f W", $0) } ?? "—")
                InfoRow(label: "GPU 功耗",
                        value: energy.gpuWatts.map { String(format: "%.2f W", $0) } ?? "—",
                        color: .purple)
                InfoRow(label: "CPU 功耗",
                        value: energy.cpuWatts.map { String(format: "%.2f W", $0) } ?? "—（本机通道不可读）")
                Text("CPU/GPU 温度走 SMC（`Tp*/Te*/Ts*` 与 `Tg*` 平均，与 macmon 口径一致；`Vitals --smc` 可核对）；系统功耗一行来自电池遥测、一行是 SMC 的 `PSTR`（互相独立）；GPU 功耗走 IOReport；CPU 功耗通道本机恒为 0（macmon 在本机同样是 0，已排除是本应用的问题）。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            HistorySection(state: state, title: "历史（CPU 温度）",
                           series: [(points: state.historyBundle.cpuTemp, color: .pink)],
                           unit: "°C", decimals: 1, zeroBased: false)

            HistorySection(state: state, title: "历史（CPU 使用率）",
                           series: [(points: state.historyBundle.cpu, color: .blue)], unit: "%")

            SectionBox(title: "进程 TOP（CPU）") {
                ProcTable(rows: state.processesByCPU, metric: "cpu")
            }
        }
    }

    private static func tempText(_ value: Double?) -> String {
        value.map { String(format: "%.1f °C", $0) } ?? "—"
    }

    private var loadText: String {
        snapshot.cpu.load.map { String(format: "%.1f", $0) }.joined(separator: " / ")
    }
}
