import Darwin
import Foundation

/// 一台 SSH 主机的探测结果（来自 `~/.ssh/config`）。
struct SSHHostProbe: Codable, Identifiable {
    var alias: String            // Host 别名
    var hostName: String         // HostName（缺省同别名）
    var user: String?
    var port: Int = 22
    var jump: String?            // ProxyJump
    var reachable: Bool?
    var latencyMS: Double?
    var note: String?

    var id: String { alias }
    var target: String { "\(hostName):\(port)" }
}

enum SSHHostsProvider {
    /// 解析 `~/.ssh/config`：Host / HostName / User / Port / ProxyJump。
    /// 带通配符的 Host 块（`Host *`、`Host 192.168.*`）跳过——它们不是可连接的目标。
    static func parse() -> [SSHHostProbe] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var hosts: [SSHHostProbe] = []
        var current: SSHHostProbe?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                // `Host name` 后面也可能只有别名（无参数行）
                if line.lowercased().hasPrefix("host ") {
                    let alias = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let current { hosts.append(current) }
                    current = alias.contains("*") || alias.contains("?")
                        ? nil
                        : SSHHostProbe(alias: alias, hostName: alias)
                }
                continue
            }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "host":
                if let current { hosts.append(current) }
                let alias = value.split(separator: " ").first.map(String.init) ?? value
                current = alias.contains("*") || alias.contains("?")
                    ? nil
                    : SSHHostProbe(alias: alias, hostName: alias)
            case "hostname":
                current?.hostName = value
            case "user":
                current?.user = value
            case "port":
                current?.port = Int(value) ?? 22
            case "proxyjump":
                current?.jump = value
                current?.note = "经 \(value) 跳板（ssh -J 探测）"
            default:
                break
            }
        }
        if let current { hosts.append(current) }
        return hosts
    }

    /// 探测一台主机。
    /// **配了 ProxyJump 的必须走 `ssh -J`**：这类条目的 HostName 常常是"跳板那一侧的地址"
    /// （比如 `127.0.0.1:2222` 的隧道只在 macmini 侧监听），直接对本机 TCP 探测是假阳性/假阴性。
    static func probe(_ host: SSHHostProbe, timeout: TimeInterval = 3) -> (Bool, Double?) {
        if let jump = host.jump {
            return sshProbe(host, jump: jump)
        }
        return tcpProbe(host, timeout: timeout)
    }

    /// 经跳板的端到端探测：`ssh -J <jump> <alias> true`（BatchMode，不会弹密码）。
    private static func sshProbe(_ host: SSHHostProbe, jump: String) -> (Bool, Double?) {
        guard let ssh = Shell.which("ssh") else { return (false, nil) }
        let start = Date()
        let result = Shell.runStatus(ssh, ["-o", "BatchMode=yes",
                                           "-o", "ConnectTimeout=5",
                                           "-o", "StrictHostKeyChecking=accept-new",
                                           "-J", jump, host.alias, "true"], timeout: 9)
        let elapsed = Date().timeIntervalSince(start) * 1000
        return (result.status == 0, result.status == 0 ? elapsed : nil)
    }

    /// 原生 TCP 连接测试（非阻塞 connect + select 超时），返回是否通 + 毫秒。
    private static func tcpProbe(_ host: SSHHostProbe, timeout: TimeInterval = 3) -> (Bool, Double?) {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.hostName, String(host.port), &hints, &result) == 0, let info = result else {
            return (false, nil)
        }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return (false, nil) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let start = Date()
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
            return (true, Date().timeIntervalSince(start) * 1000)
        }
        guard errno == EINPROGRESS else { return (false, nil) }

        // fd 必须 < FD_SETSIZE(1024)，且置位要用 bitPattern 转换：
        // `Int32(1 << 31)` 会溢出并触发 Swift trap（2026-09-24 实测崩溃：并发探测时 fd%32==31）
        guard Int(fd) < 1024 else { return (false, nil) }
        var writeSet = fd_set()
        withUnsafeMutablePointer(to: &writeSet) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { ints in
                ints[Int(fd) / 32] |= Int32(bitPattern: UInt32(1) << UInt32(Int(fd) % 32))
            }
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let selected = select(fd + 1, nil, &writeSet, nil, &tv)
        guard selected > 0 else { return (false, nil) }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        guard error == 0 else { return (false, nil) }
        return (true, Date().timeIntervalSince(start) * 1000)
    }
}
