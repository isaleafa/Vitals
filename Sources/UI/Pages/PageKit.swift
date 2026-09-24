import SwiftUI

/// 时间格式（泛型类型里不能放 static 存储属性，所以放外面）。
private enum PageShellFormatters {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 详情页外壳：标题 + 内容 + 底部状态行；页面打开时打开按需采样开关，关闭时关掉。
struct PageShell<Content: View>: View {
    @ObservedObject var state: AppState
    let title: String
    let subtitle: String
    var want: (AppState) -> Void = { _ in }
    var unwant: (AppState) -> Void = { _ in }
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // 页面内容可能很长（比如"显示空闲接口"打开后的 24 个接口），必须能滚动
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)   // 滚动条常显，否则用户不知道这页能滚
            HStack {
                Text("更新于 \(PageShellFormatters.clock.string(from: state.snapshot.time))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Text("每 1 秒刷新").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(minWidth: 440, maxWidth: .infinity, alignment: .leading)
        .onAppear { want(state) }
        .onDisappear { unwant(state) }
    }
}

/// 一行「左标签 —— 右数值」。
struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    var mono = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .monospacedDigit()
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}

/// 水平比例条。
struct MetricBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// 小图例（圆点 + 文字）。
struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// 分组盒子。
struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

/// 进程 TOP 表。
struct ProcTable: View {
    let rows: [ProcInfo]
    let metric: String        // "cpu" 或 "mem"

    var body: some View {
        VStack(spacing: 3) {
            if rows.isEmpty {
                Text("采样中…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", metric == "cpu" ? row.cpu : row.mem))
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(metric == "cpu" ? Color.blue : Color.teal)
                    Text("pid \(row.pid)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
