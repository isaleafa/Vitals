import AppKit
import SwiftUI

/// 详情窗口管理。
///
/// 为什么不用 SwiftUI 的 `Window` 场景：它不给控制窗口位置，也不能保证把窗口提到最前
/// （accessory 应用尤其容易被别的窗口压住）。自己开 `NSWindow` 就能做到：
/// **在鼠标所在那块屏幕的正中央出现 + 强制提到最前**，而且同一个页面再次点击时复用已有窗口。
@MainActor
/// 详情窗口子类：
/// 1. 确保在 Accessory App（LSUIElement）下能正常成为 Key/Main Window（红黄绿灯正常激活亮起）；
/// 2. 拦截 ⌘W 和 Esc 键，无需系统菜单直接触发 performClose 关闭窗口。
final class DetailWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘W 关闭当前窗口
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars.lowercased() == "w" {
            performClose(nil)
            return true
        }
        // Esc 关闭当前窗口（keyCode 53）
        if event.keyCode == 53 {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// 详情窗口管理。
///
/// 为什么不用 SwiftUI 的 `Window` 场景：它不给控制窗口位置，也不能保证把窗口提到最前
/// （accessory 应用尤其容易被别的窗口压住）。自己开 `NSWindow` 就能做到：
/// **在鼠标所在那块屏幕的正中央出现 + 强制提到最前**，而且同一个页面再次点击时复用已有窗口。
@MainActor
enum DetailWindows {
    private static var opened: [String: NSWindow] = [:]
    /// 捕获到的菜单栏总览窗口引用
    static weak var overviewWindow: NSWindow?

    /// 登记菜单栏弹出的总览宿主窗口
    static func registerOverviewWindow(_ window: NSWindow) {
        if !(window is DetailWindow) {
            overviewWindow = window
        }
    }

    /// 关闭菜单栏总览面板或快捷总览浮窗（若它们处于显示状态）
    static func closeOverviewPanel() {
        if let win = overviewWindow, win.isVisible {
            win.orderOut(nil)
        }
        if let win = opened["overview"], win.isVisible {
            win.orderOut(nil)
        }
    }

    /// 检查指定详情页窗口是否处于打开显示状态
    static func isWindowVisible(_ page: String) -> Bool {
        opened[page]?.isVisible == true
    }

    /// 同步窗口真实可见状态到按需采样开关（防止窗口关闭后后台仍跑 ps/smartctl/lsof）
    static func syncDemands(state: AppState) {
        let cpuOpen = isWindowVisible("cpu") || isWindowVisible("mem")
        if !cpuOpen && state.wantProcesses {
            state.wantProcesses = false
        }
        let diskOpen = isWindowVisible("disk")
        if !diskOpen && state.wantSmart {
            state.wantSmart = false
        }
        let netOpen = isWindowVisible("net")
        if !netOpen && state.wantRoutes {
            state.wantRoutes = false
        }
    }

    static func open(_ page: String, state: AppState) {
        if page == "overview" {
            let overviewVisible = opened["overview"]?.isVisible == true
            let menuPanelVisible = overviewWindow?.isVisible == true
            if overviewVisible || menuPanelVisible {
                closeOverviewPanel()
                return
            }
        }

        // 打开任意详情窗口时，立即收起右上角的菜单栏总览面板
        closeOverviewPanel()

        if let window = opened[page], window.isVisible {
            bringToFront(window)
            return
        }
        let window = opened[page] ?? makeWindow(page: page, state: state)
        opened[page] = window
        centerOnMouseScreen(window)
        bringToFront(window)
        state.onDetailPageOpened?(page)   // 打开即触发该页的"自动动作"（网络页会自动跑体检）
        // 便于脚本核对（`screencapture -l <窗口号>`）
        print("detail window \(page) id = \(window.windowNumber) frame = \(NSStringFromRect(window.frame))")
        fflush(stdout)
    }

    private static func makeWindow(page: String, state: AppState) -> NSWindow {
        let isOverview = page == "overview"
        let window = DetailWindow(contentRect: NSRect(origin: .zero, size: size(of: page)),
                                  styleMask: isOverview ? [.titled, .closable] : [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = title(of: page)
        if isOverview {
            window.level = .floating
        }
        window.contentView = NSHostingView(rootView: view(of: page, state: state))
        window.isReleasedWhenClosed = false   // 关掉后还能复用（我们持有引用）
        return window
    }

    static func size(of page: String) -> NSSize {
        switch page {
        case "net": return NSSize(width: 620, height: 760)
        case "power": return NSSize(width: 460, height: 700)
        case "services": return NSSize(width: 560, height: 680)
        case "cpu": return NSSize(width: 500, height: 620)
        case "overview": return NSSize(width: 360, height: 500)
        default: return NSSize(width: 500, height: 560)
        }
    }

    static func title(of page: String) -> String {
        switch page {
        case "cpu": return "CPU"
        case "mem": return "内存"
        case "disk": return "存储"
        case "net": return "网络"
        case "power": return "电源 · Pulse"
        case "services": return "服务 · 自启"
        case "overview": return "Vitals · 快捷总览"
        default: return "Vitals"
        }
    }

    @ViewBuilder
    static func view(of page: String, state: AppState) -> some View {
        switch page {
        case "cpu": CPUPage(state: state)
        case "mem": MemoryPage(state: state)
        case "disk": StoragePage(state: state)
        case "net": NetworkPage(state: state)
        case "power": PowerPage(state: state)
        case "services": ServicesPage(state: state)
        default: OverviewPanel(state: state)
        }
    }

    /// 放到鼠标所在屏幕（= 用户正在看的那块屏）的正中央；找不到就用主屏。
    private static func centerOnMouseScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let target = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(x: target.midX - size.width / 2,
                             y: target.midY - size.height / 2)
        window.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
    }

    private static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
    }
}
