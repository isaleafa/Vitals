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
        ZStack(alignment: .bottom) {
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
                    Text("每 1 秒刷新 · 快捷键 ⌘W / Esc 关闭").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(14)

            // 浮动轻量 Toast
            if let msg = state.toastMessage {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 0.5)
                )
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.toastMessage)
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                AppState.shared.showToast("已复制 \(label)")
            } label: {
                HStack(spacing: 3) {
                    Text(value)
                        .font(.system(size: 12, design: mono ? .monospaced : .default))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .opacity(0.4)
                }
            }
            .buttonStyle(.plain)
            .help("点击复制 \(label)")
        }
        .padding(.vertical, 1)
    }
}

/// 水平比例条。
struct MetricBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2.5, geo.size.width * min(max(fraction, 0), 1)))
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
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.50))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// 进程 TOP 表。
struct ProcTable: View {
    let rows: [ProcInfo]
    let metric: String        // "cpu" 或 "mem"

    var body: some View {
        VStack(spacing: 4) {
            if rows.isEmpty {
                Text("采样中…").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", metric == "cpu" ? row.cpu : row.mem))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(metric == "cpu" ? Color.blue : Color.teal)
                        .frame(width: 48, alignment: .trailing)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(row.pid)", forType: .string)
                        AppState.shared.showToast("已复制 PID \(row.pid)")
                    } label: {
                        Text("pid \(row.pid)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .help("点击复制 PID")
                }
                .padding(.vertical, 1)
                .contextMenu {
                    Button("拷贝 PID (\(row.pid))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(row.pid)", forType: .string)
                        AppState.shared.showToast("已复制 PID \(row.pid)")
                    }
                    Button("拷贝进程名 (\(row.name))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.name, forType: .string)
                        AppState.shared.showToast("已复制进程名")
                    }
                    Divider()
                    Button("打开系统活动监视器") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                }
            }
        }
    }
}
