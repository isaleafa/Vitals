import AppKit
import Foundation

/// 发现的新版本信息
struct UpdateInfo: Equatable {
    let version: String
    let releaseURL: URL
}

/// 轻量级新版本检查器：
/// - 零第三方依赖、零 Sparkle 臃肿后台，仅用系统标准 URLSession
/// - 采用 HEAD 请求 GitHub Release 重定向机制，零 API Rate-limit 风险
/// - 启动后后台静默探测；发现新版本时在总览面板顶部挂载低调胶囊徽标
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "isaleafa/Vitals"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.3"
    }

    /// 检查是否有新版本
    /// - Parameters:
    ///   - manual: 是否为用户手动触发（true 时弹 Toast 反馈，false 时仅在发现新版本时挂载状态）
    ///   - completion: 完成回调，供自测与命令行模式对账
    /// 检查是否有新版本
    /// - Parameters:
    ///   - manual: 是否为用户手动触发（true 时弹 Toast 反馈，false 时仅在发现新版本时挂载状态）
    ///   - completion: 完成回调，供自测与命令行模式对账
    func check(manual: Bool = false, completion: ((UpdateInfo?) -> Void)? = nil) {
        if manual {
            AppState.shared.showToast("正在检查新版本…", duration: 8.0)
        }

        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else {
            if manual {
                AppState.shared.showToast("检查更新失败: 无效的地址")
            }
            completion?(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Vitals/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else {
                completion?(nil)
                return
            }

            DispatchQueue.main.async {
                if let error = error {
                    if manual {
                        let msg = "检查更新失败: \(error.localizedDescription)"
                        AppState.shared.showToast(msg, duration: 3.0)
                        self.showManualFallbackAlertIfNeeded(title: "检查更新失败", informative: error.localizedDescription)
                    }
                    completion?(nil)
                    return
                }

                guard let http = response as? HTTPURLResponse,
                      (200...399).contains(http.statusCode),
                      let finalURL = http.url else {
                    if manual {
                        let msg = "检查更新失败 (网络或仓库异常)"
                        AppState.shared.showToast(msg, duration: 3.0)
                        self.showManualFallbackAlertIfNeeded(title: "检查更新失败", informative: "无法连接到 GitHub 仓库或网络异常，请稍后重试。")
                    }
                    completion?(nil)
                    return
                }

                let tag = finalURL.lastPathComponent
                let remoteVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

                if self.isRemoteNewer(remote: remoteVersion, local: self.currentVersion) {
                    let info = UpdateInfo(version: remoteVersion, releaseURL: finalURL)
                    AppState.shared.availableUpdate = info
                    if manual {
                        AppState.shared.showToast("发现新版本 v\(remoteVersion)，已在浏览器打开", duration: 3.0)
                        NSWorkspace.shared.open(finalURL)
                    }
                    completion?(info)
                } else {
                    AppState.shared.availableUpdate = nil
                    if manual {
                        let msg = "当前已是最新版本 (v\(self.currentVersion))"
                        AppState.shared.showToast(msg, duration: 2.5)
                        self.showManualFallbackAlertIfNeeded(title: "当前已是最新版本", informative: "Vitals v\(self.currentVersion) 目前已是最新版本。")
                    }
                    completion?(nil)
                }
            }
        }
        task.resume()
    }

    /// 若在手动检查更新完成时所有窗口都已关闭/失焦收起，通过对话框兜底确保用户不会漏掉结果
    @MainActor
    private func showManualFallbackAlertIfNeeded(title: String, informative: String) {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            return
        }
        if DetailWindows.isAnyWindowVisible {
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.alertStyle = title.contains("失败") ? .warning : .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 语义化版本号比对：remote > local 返回 true
    func isRemoteNewer(remote: String, local: String) -> Bool {
        let clean = { (s: String) -> [Int] in
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let main = trimmed.components(separatedBy: "-").first ?? trimmed
            return main.split(separator: ".").compactMap { Int($0) }
        }
        let r = clean(remote)
        let l = clean(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
