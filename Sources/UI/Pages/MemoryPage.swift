import SwiftUI

/// 内存详情页：构成条 + 交换/压力 + 进程 TOP（内存）。
struct MemoryPage: View {
    @ObservedObject var state: AppState

    private var memory: MemoryStats { state.snapshot.memory }

    private var pressureColor: Color {
        switch memory.pressure {
        case 2: return .yellow
        case 4: return .red
        default: return .teal
        }
    }

    var body: some View {
        PageShell(state: state,
                  title: "内存",
                  subtitle: "\(Fmt.gb(memory.totalBytes)) GB 物理内存",
                  want: { $0.wantProcesses = true },
                  unwant: { $0.wantProcesses = false }) {
            SectionBox(title: "总览") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(Fmt.gb(memory.usedBytes)) GB")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/ \(Fmt.gb(memory.totalBytes)) GB 已用")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(memory.pressureText)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(pressureColor.opacity(0.18)))
                        .foregroundStyle(pressureColor)
                }
                // 构成条：已用（active+wired）/ 压缩 / 可用
                GeometryReader { geo in
                    let total = max(Double(memory.totalBytes), 1)
                    let used = Double(memory.usedBytes - memory.compressedBytes) / total
                    let compressed = Double(memory.compressedBytes) / total
                    HStack(spacing: 1) {
                        Rectangle().fill(Color.teal).frame(width: geo.size.width * used)
                        Rectangle().fill(Color.orange).frame(width: geo.size.width * compressed)
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    legend(color: .teal, text: "已用 \(Fmt.gb(memory.usedBytes - memory.compressedBytes)) GB")
                    legend(color: .orange, text: "压缩 \(Fmt.gb(memory.compressedBytes)) GB")
                    legend(color: .secondary.opacity(0.35), text: "可用 \(Fmt.gb(memory.availBytes)) GB")
                    Spacer()
                }
                Sparkline(values: state.memHistory, color: pressureColor).frame(height: 34)
            }

            SectionBox(title: "明细") {
                InfoRow(label: "交换已用", value: String(format: "%.0f MB", Double(memory.swapUsedBytes) / 1_048_576))
                InfoRow(label: "压缩内存", value: "\(Fmt.gb(memory.compressedBytes)) GB", color: .orange)
                InfoRow(label: "可用（空闲+非活跃）", value: "\(Fmt.gb(memory.availBytes)) GB")
                InfoRow(label: "内存压力", value: memory.pressureText, color: pressureColor,
                        mono: false)
            }

            HistorySection(state: state, title: "历史（内存已用）",
                           series: [(points: state.historyBundle.mem, color: .teal)],
                           unit: "GB", decimals: 1)

            SectionBox(title: "进程 TOP（内存）") {
                ProcTable(rows: state.processesByMemory, metric: "mem")
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
