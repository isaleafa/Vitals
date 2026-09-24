import SwiftUI

/// 「服务 · 自启」页：登录项与后台服务审计（数据来自 launchd + BTM，见 LaunchItemsProvider）。
final class ServicesPageModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", custom = "自建", apple = "Apple", issues = "仅异常"
        var id: String { rawValue }
    }
    @Published var filter: Filter = .custom
}

struct ServicesPage: View {
    @ObservedObject var state: AppState
    @StateObject private var model = ServicesPageModel()

    private var items: [LaunchItem] { state.launchItems }

    private var filtered: [LaunchItem] {
        switch model.filter {
        case .all: return items
        case .custom: return items.filter { !$0.isApple }
        case .apple: return items.filter { $0.isApple }
        case .issues: return items.filter { $0.note != nil }
        }
    }

    private var summary: String {
        let running = items.filter(\.running).count
        let issues = items.filter { $0.note != nil }.count
        return "共 \(items.count) 项 · 运行中 \(running) · 异常 \(issues)"
    }

    var body: some View {
        PageShell(state: state,
                  title: "服务 · 自启",
                  subtitle: summary,
                  want: { $0.refreshLaunchItems?() },
                  unwant: { _ in }) {
            SectionBox(title: "登录项 / 后台服务") {
                HStack(spacing: 10) {
                    Picker("", selection: $model.filter) {
                        ForEach(ServicesPageModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button("重新扫描") { state.refreshLaunchItems?() }
                }
                Text("数据源：plist 目录 + `launchctl list`（PID/上次退出码）+ `sfltool dumpbtm`（系统「登录项」的启用状态）；全部只读、不需要 root。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                if items.isEmpty {
                    Text("扫描中…（约 1 秒）").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(filtered) { item in
                    row(item)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: LaunchItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.note != nil ? Color.red : (item.running ? Color.green : Color.secondary.opacity(0.4)))
                    .frame(width: 7, height: 7)
                Text(item.name).font(.system(size: 12, weight: .medium))
                Text(item.kind.rawValue).font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                if item.enabled == false {
                    Text("已禁用").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                Text(item.kind == .appLoginItem ? "由 App 注册" : (item.running ? "运行中 \(item.pid ?? 0)" : "未运行"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(item.identifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                if let program = item.program {
                    Text(program).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if let detail = item.detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let note = item.note {
                Text(note).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
    }
}
