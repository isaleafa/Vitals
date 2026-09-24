import SwiftUI

/// 页面本地的筛选状态（不能用 @State——CLT 工具链里 SwiftUI 的宏插件不可用）。
final class NetworkPageModel: ObservableObject {
    @Published var filter: NetworkPage.RouteFilter = .all
    @Published var showIPv6 = false
    @Published var showIdle = UserDefaults.standard.bool(forKey: "PreviewShowIdle")
    @Published var showAllServices = false
}

/// 网络详情页：接口（IP/CIDR、MAC、MTU、速率）+ 路由表（按接口分组、CIDR）+ 一句话诊断。
struct NetworkPage: View {
    @ObservedObject var state: AppState
    @StateObject private var model = NetworkPageModel()

    enum RouteFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case tunnel = "隧道"
        case direct = "直连/网关"
        case host = "主机"
        var id: String { rawValue }
    }

    private var filteredRoutes: [RouteEntry] {
        let base = model.showIPv6 ? state.routes + state.routes6 : state.routes
        switch model.filter {
        case .all: return base
        case .tunnel: return base.filter { $0.isTunnel && $0.dest != "default" }
        case .direct: return base.filter { !$0.isTunnel && !$0.isHost && $0.dest != "default" }
        case .host: return base.filter { $0.isHost }
        }
    }

    private var grouped: [(String, [RouteEntry])] {
        Dictionary(grouping: filteredRoutes, by: \.iface)
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        PageShell(state: state,
                  title: "网络",
                  subtitle: "\(state.snapshot.net.interfaces.count) 个活跃接口 · \(state.routes.count) 条 IPv4 路由"
                            + (state.routes6.isEmpty ? "" : " · \(state.routes6.count) 条 IPv6"),
                  want: {
                      $0.wantRoutes = true
                      $0.onNetworkPageOpened?()          // 一打开就立刻采一次
                  },
                  unwant: { $0.wantRoutes = false }) {
            SectionBox(title: "网络体检") {
                HStack(spacing: 10) {
                    Button(state.checksRunning ? "体检中…" : "重跑体检") { state.runNetworkChecks?() }
                        .disabled(state.checksRunning)
                    Spacer()
                    Text("打开本页自动跑；也可手动重跑").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if state.checks.isEmpty {
                    Text("正在跑：网关 / 内网 / 公网 / DNS / 代理·Google·GitHub·YouTube / 直连·百度·GitHub。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(state.checks) { check in
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(check.status))
                            .font(.system(size: 11))
                            .foregroundStyle(Self.color(check.status))
                        Text(check.title).font(.system(size: 12))
                        Spacer(minLength: 8)
                        Text(check.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(check.status == .fail ? Color.red : Color.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            SectionBox(title: "系统代理（Clash 这类工具走这里，不建隧道接口）") {
                InfoRow(label: state.proxy.anyEnabled ? "已启用" : "状态",
                        value: state.proxy.summary,
                        color: state.proxy.anyEnabled ? .orange : .secondary,
                        mono: false)
                if state.proxy.anyEnabled {
                    Text("它在代理层接管流量（应用走 127.0.0.1 的端口），所以网络接口里不会多出隧道；Clash 打开 TUN 模式才会多一个 utun。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            SectionBox(title: "接口（★ = 承载默认路由）") {
                let list = model.showIdle ? state.snapshot.net.allInterfaces : state.snapshot.net.interfaces
                HStack {
                    Text(model.showIdle
                         ? "全部 \(state.snapshot.net.allInterfaces.count) 个接口"
                         : "活跃 \(state.snapshot.net.interfaces.count) 个（另外 \(state.snapshot.net.allInterfaces.count - state.snapshot.net.interfaces.count) 个空闲）")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Toggle("显示空闲接口", isOn: $model.showIdle)
                        .toggleStyle(.switch)
                        .font(.system(size: 10))
                }
                VStack(spacing: 6) {
                    ForEach(list) { iface in
                        interfaceRow(iface)
                    }
                }
            }

            SectionBox(title: "监听端口 / 自建服务") {
                let shown = model.showAllServices
                    ? state.services
                    : state.services.filter { $0.custom || $0.note != nil }
                HStack {
                    Text(shown.isEmpty ? "读取中…" : "共 \(state.services.count) 个监听进程")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Toggle("显示全部", isOn: $model.showAllServices)
                        .toggleStyle(.switch).font(.system(size: 10))
                }
                Text("只列监听端口的服务；frpc 这类只往外连的不在内（自启项清单是后续功能）。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                ForEach(shown) { service in
                    HStack(spacing: 6) {
                        if service.custom {
                            Text("自建").font(.system(size: 8, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                        }
                        Text(service.command).font(.system(size: 11, design: .monospaced))
                        if let note = service.note {
                            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(service.portsText).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            SectionBox(title: "SSH 主机（~/.ssh/config）") {
                HStack {
                    Button(state.sshProbing ? "探测中…" : "重新探测") { state.probeSSHHosts?() }
                        .disabled(state.sshProbing)
                    Spacer()
                    Text("打开本页自动探测；不通的标红").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if state.sshHosts.isEmpty {
                    Text("没读到 ~/.ssh/config").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(state.sshHosts) { host in
                    HStack(spacing: 8) {
                        Image(systemName: Self.probeIcon(host.reachable))
                            .font(.system(size: 11))
                            .foregroundStyle(Self.probeColor(host.reachable))
                        Text(host.alias).font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(host.target).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        if let note = host.note {
                            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(host.latencyMS.map { String(format: "%.0f ms", $0) } ?? (host.reachable == false ? "不通" : "…"))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(host.reachable == false ? Color.red : Color.secondary)
                    }
                }
            }

            SectionBox(title: "路由表") {
                HStack(spacing: 10) {
                    Picker("", selection: $model.filter) {
                        ForEach(RouteFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("IPv6", isOn: $model.showIPv6)
                        .toggleStyle(.switch)
                        .font(.system(size: 10))
                }
                if let diagnosis = RoutesProvider.diagnosis(state.routes) as String?, !diagnosis.isEmpty {
                    Text(diagnosis).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if filteredRoutes.isEmpty {
                    Text(state.routes.isEmpty ? "读取中…" : "该筛选下没有路由")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(grouped, id: \.0) { iface, rows in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(iface).font(.system(size: 11, weight: .medium))
                            if iface == state.defaultRouteIface {
                                Text("★").font(.system(size: 9)).foregroundStyle(.yellow)
                            }
                            Text("\(rows.count) 条").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        ForEach(rows) { row in
                            HStack(spacing: 6) {
                                Text(row.dest)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(row.dest == "default" ? .primary : .primary)
                                if row.isViaGateway {
                                    Text("→ \(row.gateway)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                if row.isHost {
                                    Text("主机").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HistorySection(state: state, title: "历史流量",
                           series: [(points: state.historyBundle.netRx, color: .purple),
                                    (points: state.historyBundle.netTx, color: .teal)],
                           unit: "KB/s")
        }
    }

    private static func probeIcon(_ reachable: Bool?) -> String {
        guard let reachable else { return "circle" }
        return reachable ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private static func probeColor(_ reachable: Bool?) -> Color {
        guard let reachable else { return .secondary }
        return reachable ? .green : .red
    }

    private static func icon(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .skipped: return "minus.circle"
        case .pending: return "circle"
        }
    }

    private static func color(_ status: CheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .fail: return .red
        case .running: return .orange
        default: return .secondary
        }
    }

    @ViewBuilder
    private func interfaceRow(_ iface: NetIface) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if iface.name == state.defaultRouteIface {
                    Text("★").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                Text(iface.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(iface.idle ? .secondary : .primary)
                if !iface.up { Text("DOWN").font(.system(size: 9)).foregroundStyle(.red) }
                if iface.idle { Text("空闲").font(.system(size: 9)).foregroundStyle(.tertiary) }
                Spacer()
                Text("↓\(Fmt.rate(iface.rxBps)) ↑\(Fmt.rate(iface.txBps))")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                let addressText = iface.addrs.joined(separator: "  ")
                    + (iface.peer.map { "  → \($0)" } ?? "")
                Text(addressText.isEmpty ? "（无地址）" : addressText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let mac = iface.mac {
                    Text(mac).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if iface.mtu > 0 {
                    Text("mtu \(iface.mtu)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
