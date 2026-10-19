import AppKit

/// 菜单栏电池图标：**自己画一张模板图**（NSImage + isTemplate）。
///
/// 为什么不用 SF Symbol：SwiftUI 的 MenuBarExtra 会把 `Image(systemName:)` 提取成"符号名"
/// 交给 AppKit 按默认尺寸渲染——`.font()` / `.frame()` / `.resizable()` 这些修饰全部被丢掉
/// （2026-09-23 实测：怎么改菜单栏里都一模一样）。自绘才能同时满足
/// 「视觉上更大更饱满」和「占用宽度不变」。
enum MenuBarBatteryIcon {
    /// 电池主体尺寸：细长比例
    static let batterySize = NSSize(width: 19, height: 10)
    static let gap: CGFloat = 3.5

    private static var cache: [String: NSImage] = [:]

    static func image(charge: Int, plugged: Bool) -> NSImage {
        let key = "\(charge)|\(plugged)"
        if let cached = cache[key] { return cached }

        let clamped = max(0, min(charge, 100))
        let percentText = "\(clamped)%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (percentText as NSString).size(withAttributes: attr)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        let boltSymbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        let boltSize = boltSymbol?.size ?? NSSize(width: 8, height: 11)

        let height = max(batterySize.height, ceil(textSize.height))
        var totalWidth = batterySize.width + gap + textSize.width
        if plugged {
            totalWidth += gap + boltSize.width
        }

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            // 1. 电池图标（居左，垂直居中）
            let batteryY = (rect.height - batterySize.height) / 2
            let bodyRect = NSRect(x: 0.6, y: batteryY + 0.7, width: batterySize.width - 3.2, height: batterySize.height - 1.4)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.2, yRadius: 2.2)

            // 内部电量填充（纯净填充，内部不再塞挤压的闪电）
            let inner = bodyRect.insetBy(dx: 1.5, dy: 1.3)
            let level = CGFloat(clamped) / 100
            let fillRect = NSRect(x: inner.minX, y: inner.minY,
                                  width: max(0, inner.width * level), height: inner.height)
            NSColor.black.setFill()
            if fillRect.width > 0.5 {
                NSBezierPath(roundedRect: fillRect, xRadius: 1.1, yRadius: 1.1).fill()
            }

            // 外壳描边 + 右侧电池头
            NSColor.black.setStroke()
            bodyPath.lineWidth = 1.4
            bodyPath.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: bodyRect.maxX + 1.0, y: bodyRect.midY - 1.5,
                                             width: 1.6, height: 3.0),
                         xRadius: 0.8, yRadius: 0.8).fill()

            // 2. 中间电量百分比文字（垂直居中）
            let textX = batterySize.width + gap
            let textY = (rect.height - textSize.height) / 2
            (percentText as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attr)

            // 3. 右侧充电小闪电（插电时展示）
            if plugged {
                let boltX = textX + textSize.width + gap
                let boltY = (rect.height - boltSize.height) / 2
                let boltRect = NSRect(origin: NSPoint(x: boltX, y: boltY), size: boltSize)
                if let boltSymbol {
                    boltSymbol.draw(in: boltRect)
                } else {
                    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                        NSPoint(x: boltRect.minX + boltRect.width * x, y: boltRect.minY + boltRect.height * y)
                    }
                    let path = NSBezierPath()
                    path.move(to: pt(0.60, 1.00))
                    path.line(to: pt(0.15, 0.45))
                    path.line(to: pt(0.48, 0.45))
                    path.line(to: pt(0.35, 0.00))
                    path.line(to: pt(0.85, 0.55))
                    path.line(to: pt(0.52, 0.55))
                    path.close()
                    NSColor.black.setFill()
                    path.fill()
                }
            }

            return true
        }
        image.isTemplate = true   // 模板图：由系统按菜单栏明暗自动上色

        cache[key] = image
        return image
    }

    /// 告警时的图标：警告三角（也用 NSImage——菜单栏标签只认图片，不能放条件分支）。
    static let warning: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                            accessibilityDescription: "有告警") ?? NSImage(size: NSSize(width: 19, height: 10))
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = true
        return configured
    }()
}
