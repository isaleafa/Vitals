import Foundation

/// 一个正在监听 TCP 端口的服务（按进程归并）。
struct ListeningService: Codable, Identifiable {
    var pid: Int
    var command: String
    var ports: [Int]
    var note: String?
    var custom: Bool          // 是否属于"你自己装的/自建"的东西
    var id: Int { pid }

    var portsText: String { ports.map(String.init).joined(separator: ", ") }
}

/// 监听端口清单：`lsof -nP -iTCP -sTCP:LISTEN`（约 0.1~0.3 秒，只在网络页打开时低频采）。
/// 目的是回答"我的自建服务都活着吗"——Clash 内核、FRP、h3cvpn 后台、SSH…
enum ListeningPortsProvider {
    private static let notes: [String: String] = [
        "verge-mihomo": "Clash 内核（系统代理指向它）",
        "clash-verge": "Clash Verge 界面",
        "frpc": "FRP 隧道客户端（内网穿透）",
        "frps": "FRP 服务端",
        "sshd": "SSH 远程登录",
        "H3CVPNMenu": "h3cvpn 菜单栏",
        "h3cvpn": "h3cvpn 后台服务",
        "Vitals": "本应用",
        "rapportd": "Apple 连续互通",
        "ControlCenter": "系统控制中心",
        "mDNSResponder": "Bonjour（系统）",
    ]

    /// 端口 → 备注（命令名匹配不到时用）
    private static let portNotes: [Int: String] = [
        22: "SSH",
        445: "SMB 文件共享",
        548: "AFP 文件共享",
        5900: "屏幕共享",
        7890: "Clash 代理端口",
        7897: "Clash 系统代理端口",
    ]

    /// 认为"自己装的"命令名（其余算系统/其它）
    private static let customCommands: Set<String> = [
        "verge-mihomo", "clash-verge", "frpc", "frps", "h3cvpn", "H3CVPNMenu", "Vitals", "python3", "node",
    ]

    static func read() -> [ListeningService] {
        let output = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 4)
        var currentPID: Int?
        var currentCommand = ""
        var groups: [Int: (command: String, ports: [Int])] = [:]

        for line in output.split(separator: "\n") {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p": currentPID = Int(value)
            case "c": currentCommand = value
            case "n":
                guard let pid = currentPID,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                var entry = groups[pid] ?? (currentCommand, [])
                if !entry.ports.contains(port) { entry.ports.append(port) }
                groups[pid] = entry
            default:
                break
            }
        }

        return groups.map { pid, entry in
            let note = notes[entry.command] ?? entry.ports.compactMap { portNotes[$0] }.first
            return ListeningService(pid: pid,
                                    command: entry.command,
                                    ports: entry.ports.sorted(),
                                    note: note,
                                    custom: customCommands.contains(entry.command))
        }
        .sorted { lhs, rhs in
            if lhs.custom != rhs.custom { return lhs.custom }        // 自建的排前面
            return lhs.command.localizedCompare(rhs.command) == .orderedAscending
        }
    }
}
