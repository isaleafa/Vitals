import Foundation
import ServiceManagement

/// 开机自启。
/// 首选 macOS 13+ 的 `SMAppService`（正规做法，能在「系统设置 → 通用 → 登录项」里开关）；
/// 如果系统拒绝（例如未公证/临时签名），退回写一个 LaunchAgent —— 本机 h3cvpn 就是这么自启的，可靠。
enum LoginItem {
    struct Result {
        var enabled: Bool
        var message: String?
    }

    static let agentLabel = "top.liyi830.vitals"

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) -> Result {
        if enabled { return enable() }
        return disable()
    }

    private static func enable() -> Result {
        do {
            try SMAppService.mainApp.register()
            removeAgent()   // 别两套同时生效
            switch SMAppService.mainApp.status {
            case .enabled:
                return Result(enabled: true, message: nil)
            case .requiresApproval:
                return Result(enabled: true, message: "需在「系统设置 → 通用 → 登录项」里允许 Vitals")
            default:
                return Result(enabled: isEnabled, message: nil)
            }
        } catch {
            let ok = writeAgent()
            return Result(enabled: ok,
                          message: ok ? "已改用 LaunchAgent 自启（系统登录项被拒：\(error.localizedDescription)）"
                                      : "开启失败：\(error.localizedDescription)")
        }
    }

    private static func disable() -> Result {
        var message: String?
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            if isEnabled { message = error.localizedDescription }
        }
        removeAgent()
        return Result(enabled: isEnabled, message: message)
    }

    // MARK: - LaunchAgent 兜底

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private static func writeAgent() -> Bool {
        let executable = Bundle.main.executablePath ?? ""
        guard !executable.isEmpty else { return false }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: agentURL)) != nil else { return false }
        // 立刻生效（之后每次登录也会自动加载）
        _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentURL.path], timeout: 3)
        return true
    }

    private static func removeAgent() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"], timeout: 3)
        try? FileManager.default.removeItem(at: agentURL)
    }
}
