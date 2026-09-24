import Foundation

/// 一条路由。目标统一成完整 CIDR（netstat 给的是简写，如 `10.0.0/24`、`192.168.0/16`、`127`）。
struct RouteEntry: Codable, Identifiable, Hashable {
    var dest: String            // "default" 或 CIDR
    var gateway: String
    var flags: String
    var iface: String

    var id: String { "\(dest)|\(iface)|\(gateway)" }
    var isHost: Bool { flags.contains("H") }
    var isViaGateway: Bool { flags.contains("G") }
    var isTunnel: Bool { iface.hasPrefix("utun") || iface.hasPrefix("gif") || iface.hasPrefix("ipsec") }

    var kindText: String {
        if isHost { return "主机" }
        if isTunnel { return "隧道" }
        return dest == "default" ? "默认" : "直连/网关"
    }
}

enum RoutesProvider {
    /// netstat -rn 实测 6ms，够快；原生实现建议改 sysctl NET_RT_DUMP。
    static func read(family: String = "inet") -> [RouteEntry] {
        let output = Shell.run("/usr/sbin/netstat", ["-rn", "-f", family], timeout: 2)
        var rows: [RouteEntry] = []
        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 4,
                  !["Routing", "Internet:", "Internet6:", "Destination"].contains(tokens[0]) else { continue }
            let rawDest = tokens[0]
            let dest: String
            if rawDest == "default" {
                dest = "default"
            } else if family == "inet" {
                dest = normalize(rawDest)
            } else {
                if rawDest.hasPrefix("ff") || rawDest.hasPrefix("fe80") { continue }   // 多播/链路本地不列
                dest = rawDest
            }
            rows.append(RouteEntry(dest: dest, gateway: tokens[1], flags: tokens[2], iface: tokens[3]))
        }
        return rows
    }

    /// `10.0.0/24` → `10.0.0.0/24`；`10.8.0.1` → `/32`；`127` → `127.0.0.0/8`。
    static func normalize(_ token: String) -> String {
        var address = token
        var prefix: Int?
        if let slash = token.firstIndex(of: "/") {
            address = String(token[..<slash])
            prefix = Int(token[token.index(after: slash)...])
        }
        var octets = address.split(separator: ".").compactMap { Int($0) }
        guard !octets.isEmpty else { return token }
        if prefix == nil {
            prefix = octets.count == 4 ? 32 : (octets[0] < 128 ? 8 : (octets[0] < 192 ? 16 : 24))
        }
        while octets.count < 4 { octets.append(0) }
        guard let bits = prefix else { return token }
        var value: UInt32 = 0
        for octet in octets { value = (value << 8) | UInt32(octet & 0xFF) }
        if bits > 0 { value &= bits >= 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - bits)) }
        return "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)/\(bits)"
    }

    /// 一句话诊断：把有意义的几条路由说成人话。
    static func diagnosis(_ routes: [RouteEntry]) -> String {
        var parts: [String] = []
        if let def = routes.first(where: { $0.dest == "default" }) {
            parts.append("公网走 \(def.iface)（网关 \(def.gateway)）")
        }
        let tunnels = routes.filter { $0.isTunnel && $0.dest != "default" && !$0.isHost && $0.dest != "127.0.0.0/8" }
        if !tunnels.isEmpty {
            let text = tunnels.prefix(3).map { "\($0.dest) → \($0.iface)" }.joined(separator: "、")
            parts.append("走隧道：\(text)")
        }
        return parts.joined(separator: "；")
    }
}
