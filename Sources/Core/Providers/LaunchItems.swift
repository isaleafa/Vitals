import Foundation

/// 一条登录项 / 后台服务。
struct LaunchItem: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case userAgent = "用户代理"
        case systemAgent = "系统代理"
        case systemDaemon = "系统守护进程"
        case appLoginItem = "App 登录项"
        case stale = "遗留文件"
    }

    var identifier: String
    var name: String
    var kind: Kind
    var enabled: Bool?          // BTM 的 Disposition（System Settings 里那个开关）
    var program: String?
    var plistPath: String?
    var runAtLoad: Bool?
    var keepAlive: Bool?
    var pid: Int?
    var lastExit: Int?
    var lastUse: String?
    var note: String?           // 问题（红色显示）
    var detail: String?         // 中性信息（灰字显示）：上次使用时间、ProcessType 等
    var isApple: Bool
    var id: String { identifier + "|" + kind.rawValue }

    var running: Bool { pid != nil }
}

/// 登录项 / 后台服务审计。数据源（都是系统自带、**不需要 root**）：
/// 1. 三个 plist 目录：`~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`
/// 2. `launchctl list`（用户域）与 `launchctl print system/<label>`（系统域）→ PID / 上次退出码
/// 3. **`sfltool dumpbtm`** —— 系统「设置 → 通用 → 登录项」背后的 BTM 数据库，给出启用/禁用状态与最后使用时间
///    （这是本项最关键的"成熟数据源"：与其自己推断，不如读系统自己的账本）
enum LaunchItemsProvider {
    static func read() -> [LaunchItem] {
        var items: [LaunchItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // ── 1) plist 扫描 ──
        let directories: [(path: String, kind: LaunchItem.Kind)] = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
        for (path, kind) in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for file in files {
                let full = "\(path)/\(file)"
                guard file.hasSuffix(".plist") else {
                    if file.contains(".plist.") {
                        items.append(LaunchItem(identifier: file, name: file, kind: .stale,
                                                program: nil, plistPath: full,
                                                note: "不是自启项（备份/残留文件）", isApple: false))
                    }
                    continue
                }
                guard let data = FileManager.default.contents(atPath: full),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                var item = LaunchItem(identifier: label, name: label, kind: kind,
                                      program: programText(plist), plistPath: full,
                                      runAtLoad: plist["RunAtLoad"] as? Bool,
                                      keepAlive: plist["KeepAlive"] as? Bool ?? (plist["KeepAlive"] != nil ? true : nil),
                                      isApple: label.hasPrefix("com.apple."))
                if let processType = plist["ProcessType"] as? String { item.detail = "ProcessType=\(processType)" }
                items.append(item)
            }
        }

        // ── 2) launchctl：PID / 上次退出码 ──
        var runtime: [String: (pid: Int?, exit: Int?)] = [:]
        for line in Shell.run("/bin/launchctl", ["list"], timeout: 4).split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let pid = Int(parts[0])
            let exit = Int(parts[1])
            runtime[parts[2]] = (pid, exit)
        }
        // 系统域的守护进程要单独查（launchctl list 只给用户域）
        for item in items where item.kind == .systemDaemon {
            let output = Shell.run("/bin/launchctl", ["print", "system/\(item.identifier)"], timeout: 2)
            for line in output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("pid = "), let value = Int(text.dropFirst(6)) {
                    runtime[item.identifier] = (value, runtime[item.identifier]?.exit)
                }
            }
        }

        // ── 3) BTM（System Settings 的账本）──
        var btm: [String: (enabled: Bool, name: String?, lastUse: String?)] = [:]
        let dump = Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 8)
        var currentIdentifier: String?
        var currentEnabled: Bool?
        var currentName: String?
        var currentLastUse: String?
        func flush() {
            guard let identifier = currentIdentifier else { return }
            btm[normalize(identifier)] = (currentEnabled ?? false,
                                          currentName == "(null)" ? nil : currentName,
                                          currentLastUse)
            currentIdentifier = nil; currentEnabled = nil; currentName = nil; currentLastUse = nil
        }
        for line in dump.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") && text.hasSuffix(":") { flush(); continue }
            func value(_ key: String) -> String? {
                guard text.hasPrefix(key + ":") else { return nil }
                return text.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
            if let v = value("Identifier") { currentIdentifier = v }
            if let v = value("Name") { currentName = v }
            if let v = value("Last Use") { currentLastUse = v }
            if let v = value("Disposition") { currentEnabled = v.contains("enabled") }
        }
        flush()

        // ── 合并 ──
        var merged: [LaunchItem] = []
        for var item in items {
            let key = normalize(item.identifier)
            if let info = btm[key] {
                item.enabled = info.enabled
                if item.name == item.identifier, let name = info.name { item.name = name }
                if let lastUse = info.lastUse { item.detail = "上次使用 \(lastUse)" }
            }
            if let entry = runtime[item.identifier] {
                item.pid = entry.pid
                item.lastExit = entry.exit
            }
            if item.pid == nil, let exit = item.lastExit, exit != 0 {
                let reason: String
                switch exit {
                case -9: reason = "上次被强制结束（SIGKILL）"
                case -15: reason = "上次被终止（SIGTERM）"
                case 255: reason = "上次异常退出（exit 255）"
                default: reason = "上次以退出码 \(exit) 结束"
                }
                item.note = reason
            }
            if item.enabled == false, item.note == nil {
                item.note = "已在「系统设置 → 登录项」里禁用"
            }
            merged.append(item)
        }

        // BTM 里有、plist 目录里没有的（App 注册的登录项，如 Vitals 自己）
        let known = Set(merged.map { normalize($0.identifier) })
        for (identifier, info) in btm where !known.contains(identifier) && !identifier.hasPrefix("com.apple.") {
            merged.append(LaunchItem(identifier: identifier, name: info.name ?? identifier,
                                     kind: .appLoginItem, enabled: info.enabled,
                                     program: nil, plistPath: nil,
                                     detail: info.lastUse.map { "上次使用 \($0)" }, isApple: false))
        }

        return merged.sorted { lhs, rhs in
            if (lhs.note != nil) != (rhs.note != nil) { return lhs.note != nil }   // 有问题的排前面
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// BTM 的 Identifier 前面会带类型数字（`16.` 守护进程、`8.` 代理、`2.` App 项…），剥掉再比对。
    private static func normalize(_ identifier: String) -> String {
        var text = identifier
        while let dot = text.firstIndex(of: "."), Int(text[text.startIndex..<dot]) != nil {
            text = String(text[text.index(after: dot)...])
        }
        return text
    }

    private static func programText(_ plist: [String: Any]) -> String? {
        if let arguments = plist["ProgramArguments"] as? [String] {
            return arguments.joined(separator: " ")
        }
        return plist["Program"] as? String
    }
}
