import CFNetwork
import Foundation

/// 系统代理设置。Clash 这类工具默认走「系统代理」而不是建隧道接口——
/// 网络页必须把这一层也显示出来，否则用户会以为"第二个 VPN 不见了"。
struct ProxyInfo: Codable {
    var http: String?
    var https: String?
    var socks: String?
    var pacEnabled = false
    var processName: String?      // 监听该端口的进程名（如 verge-mihomo）

    var anyEnabled: Bool { http != nil || https != nil || socks != nil || pacEnabled }

    var port: Int? {
        for endpoint in [http, https, socks] {
            if let endpoint, let last = endpoint.split(separator: ":").last, let value = Int(last) { return value }
        }
        return nil
    }

    var summary: String {
        var parts: [String] = []
        if let http { parts.append("HTTP \(http)") }
        if let https, https != http { parts.append("HTTPS \(https)") }
        if let socks, socks != http { parts.append("SOCKS \(socks)") }
        if pacEnabled { parts.append("PAC 已启用") }
        if parts.isEmpty { return "未启用" }
        if let processName { parts.append("（\(processName)）") }
        return parts.joined(separator: " · ")
    }
}

enum ProxyProvider {
    static func read() -> ProxyInfo {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return ProxyInfo()
        }
        func endpoint(_ enableKey: String, _ hostKey: String, _ portKey: String) -> String? {
            guard (raw[enableKey] as? Int) == 1, let port = raw[portKey] as? Int else { return nil }
            return "\(raw[hostKey] as? String ?? "127.0.0.1"):\(port)"
        }
        var info = ProxyInfo()
        info.http = endpoint("HTTPEnable", "HTTPProxy", "HTTPPort")
        info.https = endpoint("HTTPSEnable", "HTTPSProxy", "HTTPSPort")
        info.socks = endpoint("SOCKSEnable", "SOCKSProxy", "SOCKSPort")
        info.pacEnabled = (raw["ProxyAutoConfigEnable"] as? Int) == 1
        return info
    }

    /// 谁在监听这个端口（低频调用：约 100~200ms）。
    static func listenerName(port: Int) -> String? {
        guard let lsof = Shell.which("lsof") else { return nil }
        let output = Shell.run(lsof, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "c"], timeout: 2)
        for line in output.split(separator: "\n") where line.hasPrefix("c") {
            return String(line.dropFirst())
        }
        return nil
    }
}
