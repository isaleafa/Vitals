import Foundation

enum CheckStatus: String, Codable {
    case pending, running, ok, fail, skipped
}

struct NetworkCheckResult: Codable, Identifiable {
    var id: String
    var title: String
    var status: CheckStatus = .pending
    var summary: String = "等待中…"
}

/// 网络一键体检：跑一串只读探测（ping / dig / curl），逐条回填结果。
/// 全部要开子进程 —— 调用方负责放到后台队列（Sampler 里就是这么做的）。
enum NetworkCheckProvider {
    struct Item {
        var id: String
        var title: String
    }

    /// 需要经过系统代理才能访问的站点（国内直连会被墙）——测的就是"代理到底通不通"。
    static let proxiedSites: [(id: String, title: String, url: String, expect: String)] = [
        ("google", "Google", "https://www.google.com/generate_204", "204"),
        ("github", "GitHub", "https://github.com/", "200"),
        ("youtube", "YouTube", "https://www.youtube.com/", "200"),
    ]

    static func items() -> [Item] {
        var list = [
            Item(id: "gateway", title: "默认网关"),
            Item(id: "intranet", title: "内网主机（走隧道）"),
            Item(id: "public", title: "公网（国内 ping）"),
            Item(id: "dns", title: "DNS 解析"),
        ]
        list += proxiedSites.map { Item(id: "proxy-\($0.id)", title: "代理 · \($0.title)") }
        list += [
            Item(id: "direct-baidu", title: "直连 · 百度"),
            Item(id: "direct-github", title: "直连 · GitHub"),
        ]
        return list
    }

    /// 内网探测目标（走 h3cvpn 隧道的机器）
    static let intranetHost = "192.168.1.50"
    /// 公网探测目标（国内可达，不用代理）
    static let publicHost = "223.5.5.5"

    static func run(_ id: String, proxy: String?) -> NetworkCheckResult {
        var result = NetworkCheckResult(id: id, title: items().first { $0.id == id }?.title ?? id)
        switch id {
        case "gateway":
            let gateway = defaultGateway() ?? ""
            guard !gateway.isEmpty else {
                result.status = .fail
                result.summary = "没找到默认网关"
                return result
            }
            let ping = pingLatency(gateway)
            result.status = ping.ok ? .ok : .fail
            result.summary = ping.ok
                ? "\(gateway) · 延迟 \(format(ping.ms))（经 \(interface(to: gateway) ?? "?")）"
                : "\(gateway) 不通"
        case "intranet":
            let ping = pingLatency(intranetHost)
            let route = interface(to: intranetHost) ?? "?"
            result.status = ping.ok ? .ok : .fail
            result.summary = ping.ok
                ? "\(intranetHost) · 延迟 \(format(ping.ms))（经 \(route)）"
                : "\(intranetHost) 不通（经 \(route)）"
        case "public":
            let ping = pingLatency(publicHost)
            result.status = ping.ok ? .ok : .fail
            result.summary = ping.ok
                ? "\(publicHost) · 延迟 \(format(ping.ms))（经 \(interface(to: publicHost) ?? "?")）"
                : "\(publicHost) 不通"
        case "dns":
            let dns = resolve("www.apple.com")
            result.status = dns.address == nil ? .fail : .ok
            if let address = dns.address {
                result.summary = "www.apple.com → \(address)（\(dns.ms) ms）"
            } else {
                result.summary = "解析失败"
            }
        case let id where id.hasPrefix("proxy-"):
            guard let proxy, !proxy.isEmpty else {
                result.status = .skipped
                result.summary = "未启用系统代理"
                return result
            }
            let key = String(id.dropFirst("proxy-".count))
            guard let site = proxiedSites.first(where: { $0.id == key }) else {
                result.status = .skipped
                return result
            }
            let scheme = proxy.contains(":") ? "http://\(proxy)" : "http://127.0.0.1:\(proxy)"
            let probe = curl(httpCode: site.expect, args: ["-x", scheme, site.url], extraHeaders: key != "google")
            result.status = probe.ok ? .ok : .fail
            result.summary = "\(probe.summary)（经 \(proxy)）"
        case "direct-baidu":
            let probe = curl(httpCode: "200", args: ["--noproxy", "*", "https://www.baidu.com"], extraHeaders: true)
            result.status = probe.ok ? .ok : .fail
            result.summary = probe.summary + "（绕过代理）"
        case "direct-github":
            let probe = curl(httpCode: "200", args: ["--noproxy", "*", "https://github.com/"], extraHeaders: true)
            result.status = probe.ok ? .ok : .fail
            result.summary = probe.summary + "（绕过代理）"
        default:
            result.status = .skipped
        }
        return result
    }

    // MARK: - 底层探测

    static func defaultGateway() -> String? {
        let output = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 2)
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("gateway:") {
                return text.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 目标地址走哪个接口（`route -n get` 会给出 interface）。
    static func interface(to host: String) -> String? {
        let output = Shell.run("/sbin/route", ["-n", "get", host], timeout: 2)
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("interface:") {
                return text.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func pingLatency(_ host: String) -> (ok: Bool, ms: Double) {
        let output = Shell.run("/sbin/ping", ["-c", "1", "-t", "2", host], timeout: 4)
        guard output.contains("1 packets received") || output.contains("1 received") else { return (false, 0) }
        if let range = output.range(of: "time=") {
            let tail = output[range.upperBound...]
            let number = tail.prefix { $0.isNumber || $0 == "." }
            return (true, Double(number) ?? 0)
        }
        return (true, 0)
    }

    static func resolve(_ domain: String) -> (address: String?, ms: Int) {
        let output = Shell.run("/usr/bin/dig", ["+time=2", "+tries=1", domain], timeout: 4)
        var address: String?
        var ms = 0
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.hasPrefix(";;") && text.contains("\tA\t") {
                address = text.split(separator: "\t").last.map(String.init)
            }
            if text.hasPrefix(";; Query time:") {
                ms = Int(text.split(separator: " ").dropLast(1).last.map(String.init) ?? "0") ?? 0
            }
        }
        return (address, ms)
    }

    /// 用 curl 探测（走/不走代理），返回状态码与耗时。
    static func curl(httpCode expected: String, args: [String], extraHeaders: Bool = false) -> (ok: Bool, summary: String) {
        var arguments = ["-s", "-o", "/dev/null", "--max-time", "6",
                         "-w", "%{http_code} %{time_total}"] + args
        if extraHeaders { arguments.insert("-I", at: 0) }   // 直连那条只取响应头，更快
        let output = Shell.run("/usr/bin/curl", arguments, timeout: 8)
        let parts = output.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return (false, "无响应") }
        let code = parts[0]
        let seconds = Double(parts[1]) ?? 0
        let ok = code == expected || (extraHeaders && code == "301") || (extraHeaders && code == "302")
        return (ok, "HTTP \(code) · \(format(seconds * 1000))")
    }

    static func format(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.2f s", ms / 1000) : String(format: "%.0f ms", ms)
    }
}
