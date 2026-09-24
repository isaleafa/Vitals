import AppKit
import SwiftUI

/// 详情窗口管理。
///
/// 为什么不用 SwiftUI 的 `Window` 场景：它不给控制窗口位置，也不能保证把窗口提到最前
/// （accessory 应用尤其容易被别的窗口压住）。自己开 `NSWindow` 就能做到：
/// **在鼠标所在那块屏幕的正中央出现 + 强制提到最前**，而且同一个页面再次点击时复用已有窗口。
@MainActor
enum DetailWindows {
    private static var opened: [String: NSWindow] = [:]

    static func open(_ page: String, state: AppState) {
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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size(of: page)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title(of: page)
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
    }
}
