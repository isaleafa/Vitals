import SwiftUI

/// 存储详情页：容量 + 实时读写 + SMART 摘要。
struct StoragePage: View {
    @ObservedObject var state: AppState

    private var disk: DiskStats { state.snapshot.disk }
    private var used: UInt64 { disk.totalBytes > disk.freeBytes ? disk.totalBytes - disk.freeBytes : 0 }

    var body: some View {
        PageShell(state: state,
                  title: "存储",
                  subtitle: "内置 SSD（APFS 数据卷口径）",
                  want: { $0.wantSmart = true },
                  unwant: { $0.wantSmart = false }) {
            SectionBox(title: "容量") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.bytes(used))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("已用 / 共 \(Fmt.bytes(disk.totalBytes))，可用 \(Fmt.bytes(disk.freeBytes))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                MetricBar(fraction: Double(used) / max(Double(disk.totalBytes), 1), color: .green, height: 9)
            }

            SectionBox(title: "实时吞吐") {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    rate(title: "读", value: Fmt.rate(disk.readBps), color: .blue)
                    rate(title: "写", value: Fmt.rate(disk.writeBps), color: .orange)
                    rate(title: "IOPS", value: String(format: "%.0f", disk.iops), color: .secondary)
                    Spacer()
                }
                Sparkline(values: state.diskHistory, color: .green).frame(height: 38)
            }

            HistorySection(state: state, title: "历史吞吐",
                           series: [(points: state.historyBundle.diskRead, color: .blue),
                                    (points: state.historyBundle.diskWrite, color: .orange)],
                           unit: "MB/s", decimals: 1)

            SectionBox(title: "SSD 健康（smartctl）") {
                InfoRow(label: "NAND 温度（传感器）",
                        value: state.snapshot.thermal.nandTemp.map { String(format: "%.1f °C", $0) } ?? "—",
                        color: .pink)
                if state.smart.isEmpty {
                    Text("读取中…（打开这一页会立刻采一次）").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ForEach(state.smart, id: \.label) { item in
                        InfoRow(label: item.label, value: item.value)
                    }
                }
            }
        }
    }

    private func rate(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
        }
    }
}
