import Foundation

/// `Vitals --selftest`：纯函数的已知输入 → 输出断言，返回失败数（0 = 全过，进程退出码）。
///
/// 被测的都是解析 / 差分逻辑（netstat 简写、CPU tick 回绕、ssh 配置、BTM 前缀、历史聚合、
/// 格式化）——它们不碰 IOKit，恰恰是系统更新 / 环境变化时**最容易悄悄坏**、又最难从 UI
/// 上看出来的部分。不需要 Xcode / 测试框架，和 `--dump` / `--bench` 一套自检风格。
enum SelfTest {
    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("  ✓ \(name)")
            } else {
                failed += 1
                print("  ✗ \(name)")
            }
        }
        func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
            check("\(name)（实际 \(actual)，期望 \(expected)）", actual == expected)
        }

        print("路由 CIDR 规范化（netstat 简写 → 完整 CIDR）：")
        equal("10.0.0/24", RoutesProvider.normalize("10.0.0/24"), "10.0.0.0/24")
        equal("192.168.0/16", RoutesProvider.normalize("192.168.0/16"), "192.168.0.0/16")
        equal("四段无前缀 = /32", RoutesProvider.normalize("10.8.0.1"), "10.8.0.1/32")
        equal("127 = /8", RoutesProvider.normalize("127"), "127.0.0.0/8")
        equal("169.254 = /16", RoutesProvider.normalize("169.254"), "169.254.0.0/16")
        equal("224.0.0 = /24", RoutesProvider.normalize("224.0.0"), "224.0.0.0/24")
        equal("非法输入原样返回", RoutesProvider.normalize("utun"), "utun")

        print("CPU 每核差分（32 位 tick 回绕用 &-）：")
        let wrap = CPUProvider.usage(prev: [[.max, 0, 100, 0]], cur: [[16, 0, 200, 0]])
        equal("条目数", wrap.count, 1)
        check("回绕后按差值算（user +17 / 总 117）",
              wrap.first.map { abs($0 - 100.0 * 17.0 / 117.0) < 0.001 } ?? false)
        equal("总 tick 为 0 给 0", CPUProvider.usage(prev: [[0, 0, 0, 0]], cur: [[0, 0, 0, 0]]).first ?? -1, 0.0)
        equal("核数变化放弃差分", CPUProvider.usage(prev: [[0, 0, 0, 0]], cur: [[0, 0, 0, 0], [0, 0, 0, 0]]).count, 0)

        print("SSH 配置解析（tab 分隔 / 一行多别名 / 通配跳过 / ProxyJump）：")
        let config = [
            "# 注释",
            "Host\tmacmini\ttab-alias",
            "\tHostName 192.168.1.10",
            "\tPort 2222",
            "Host macpro *",
            "\tHostName 1.2.3.4",
            "Host vpn",
            "\tProxyJump macmini",
        ].joined(separator: "\n")
        let hosts = SSHHostsProvider.parse(text: config)
        equal("条目数（多别名各建一条，通配 * 不建）", hosts.count, 4)
        equal("tab 别名同享块内 HostName/Port",
              hosts.contains { $0.alias == "tab-alias" && $0.hostName == "192.168.1.10" && $0.port == 2222 }, true)
        equal("通配符不建条目", hosts.contains { $0.alias.contains("*") }, false)
        equal("ProxyJump 记跳板", hosts.last?.jump, "macmini")

        print("BTM Identifier 前缀剥离（登录项比对用）：")
        equal("16. 守护进程", LaunchItemsProvider.normalize("16.local.h3cvpn.daemon"), "local.h3cvpn.daemon")
        equal("2. App 项", LaunchItemsProvider.normalize("2.top.liyi830.vitals"), "top.liyi830.vitals")
        equal("无前缀不动", LaunchItemsProvider.normalize("com.apple.foo"), "com.apple.foo")

        print("历史聚合（桶均值 / 跨桶 / 缺字段跳过）：")
        func record(_ t: Int, cpu: Double, temp: Double?) -> HistoryRecord {
            HistoryRecord(t: t, cpu: cpu, mem: 0, press: 1, swap: 0, dr: 0, dw: 0, nrx: 0, ntx: 0,
                          pin: 0, pdis: 0, chg: 100, cc: temp, h: nil, hr: nil, cap: nil, cyc: nil)
        }
        let records = [record(60, cpu: 10, temp: 40), record(120, cpu: 30, temp: 50), record(180, cpu: 20, temp: nil)]
        let cpu300 = HistoryBundle.aggregate(records, bucket: 300, metric: { $0.cpu })
        equal("同桶取均值", cpu300.count == 1 && cpu300[0].t == 0 && abs(cpu300[0].value - 20) < 0.001, true)
        let cpu120 = HistoryBundle.aggregate(records, bucket: 120, metric: { $0.cpu })
        equal("跨桶分点（60→0，120/180→120 且取均值）",
              cpu120.count == 2 && cpu120[0].t == 0 && cpu120[1].t == 120 && abs(cpu120[1].value - 25) < 0.001, true)
        let temp300 = HistoryBundle.aggregate(records, bucket: 300, metric: { $0.cc })
        equal("缺字段的记录跳过不补 0", temp300.count == 1 && abs(temp300[0].value - 45) < 0.001, true)
        equal("空记录给空序列", HistoryBundle.aggregate([], bucket: 60, metric: { $0.cpu }).count, 0)

        print("内网体检的路径文案（隧道 vs 本地网遮蔽）：")
        equal("utun7 记走隧道", NetworkCheckProvider.pathText("utun7"), "走隧道 utun7")
        equal("en0 记经本地网", NetworkCheckProvider.pathText("en0"), "经 en0")
        equal("查不到接口给未知", NetworkCheckProvider.pathText(nil), "路径未知")

        print("格式化与杂项：")
        equal("Fmt.bytes 十进制", Fmt.bytes(1_500_000_000), "1.5 GB")
        equal("Fmt.rate", Fmt.rate(2048), "2 KB/s")
        equal("Fmt.duration 天", Fmt.duration(90_061), "1天1小时")
        equal("Fmt.duration 时分", Fmt.duration(3_660), "1小时1分")
        var proxy = ProxyInfo()
        proxy.http = "127.0.0.1:7897"
        equal("ProxyInfo.port 取端口", proxy.port, 7897)
        equal("MenuBarStyle 往返", MenuBarStyle(rawValue: MenuBarStyle.cpuMem.rawValue) == .cpuMem, true)
        equal("未知样式回默认", MenuBarStyle(rawValue: "bogus") == nil, true)

        print(failed == 0 ? "✓ 全部通过" : "✗ \(failed) 项失败")
        return failed == 0 ? 0 : 1
    }
}
