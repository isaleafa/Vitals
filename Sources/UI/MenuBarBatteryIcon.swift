import AppKit

/// 菜单栏电池图标：**自己画一张模板图**（NSImage + isTemplate）。
///
/// 为什么不用 SF Symbol：SwiftUI 的 MenuBarExtra 会把 `Image(systemName:)` 提取成"符号名"
/// 交给 AppKit 按默认尺寸渲染——`.font()` / `.frame()` / `.resizable()` 这些修饰全部被丢掉
/// （2026-09-23 实测：怎么改菜单栏里都一模一样）。自绘才能同时满足
/// 「视觉上更大更饱满」和「占用宽度不变」。
enum MenuBarBatteryIcon {
    /// 画布尺寸：宽度与系统符号的默认占位一致（不变），高度做扁 → 看起来更细长（用户偏好长条，不要敦实）。
    static let size = NSSize(width: 19, height: 10)

    private static var cache: [String: NSImage] = [:]

    static func image(charge: Int, plugged: Bool) -> NSImage {
        let key = "\(charge)|\(plugged)"
        if let cached = cache[key] { return cached }

        let image = NSImage(size: size)
        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = true   // 模板图：由系统按菜单栏明暗自动上色
        }

        // 细长比例：宽 15.8 / 高 8.6 ≈ 1.84:1（系统电池是 1.7:1 左右，之前那版是 1.34:1 显得敦实）
        let bodyRect = NSRect(x: 0.6, y: 0.7, width: size.width - 3.2, height: size.height - 1.4)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.2, yRadius: 2.2)

        // 内部电量填充
        let inner = bodyRect.insetBy(dx: 1.5, dy: 1.3)
        let level = CGFloat(max(0, min(charge, 100))) / 100
        let fillRect = NSRect(x: inner.minX, y: inner.minY,
                              width: max(0, inner.width * level), height: inner.height)
        NSColor.black.setFill()
        if fillRect.width > 0.5 {
            NSBezierPath(roundedRect: fillRect, xRadius: 1.1, yRadius: 1.1).fill()
        }

        // 接电：把闪电从填充里"挖空"（和系统图标一个画法）
        if plugged {
            NSGraphicsContext.current?.compositingOperation = .clear
            boltPath(in: bodyRect).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        // 外壳描边 + 右侧电池头
        NSColor.black.setStroke()
        bodyPath.lineWidth = 1.4
        bodyPath.stroke()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: bodyRect.maxX + 1.0, y: bodyRect.midY - 1.5,
                                         width: 1.6, height: 3.0),
                     xRadius: 0.8, yRadius: 0.8).fill()

        cache[key] = image
        return image
    }

    /// 告警时的图标：警告三角（也用 NSImage——菜单栏标签只认图片，不能放条件分支）。
    static let warning: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                            accessibilityDescription: "有告警") ?? NSImage(size: size)
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = true
        return configured
    }()

    private static func boltPath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + w * x, y: rect.minY + h * y)
        }
        let path = NSBezierPath()
        path.move(to: point(0.58, 0.88))
        path.line(to: point(0.33, 0.46))
        path.line(to: point(0.48, 0.46))
        path.line(to: point(0.42, 0.10))
        path.line(to: point(0.67, 0.55))
        path.line(to: point(0.52, 0.55))
        path.close()
        return path
    }
}
