import AppKit

/// 菜单栏显示样式——**只做两档预设**（"没人会调的设置项不做"这条原则不变，这里只留真会用的两种）。
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case battery        // 电池图标：用来替掉系统自带的电池项
    case cpuMem         // CPU + 内存：常显的两个数

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "电池"
        case .cpuMem: return "CPU + 内存"
        }
    }
}

/// 菜单栏图标渲染（电池 / CPU + 内存二选一）。
///
/// ⚠️ 约束同 `MenuBarBatteryIcon`：MenuBarExtra 的 label 必须是**单个 Image**——
/// SwiftUI 的 Text / font / frame 在菜单栏里全会被丢掉，所以"数字"也得自己画进 NSImage。
enum MenuBarIcon {
    static func image(style: MenuBarStyle, snapshot: Snapshot) -> NSImage {
        switch style {
        case .battery:
            return MenuBarBatteryIcon.image(charge: snapshot.power.charge,
                                            plugged: snapshot.power.externalPower)
        case .cpuMem:
            return cpuMemoryImage(cpu: snapshot.cpu.total,
                                  memoryGB: Double(snapshot.memory.usedBytes) / 1_073_741_824)
        }
    }

    // MARK: - CPU + 内存

    private static var cacheKey: String?
    private static var cached: NSImage?

    /// `27% │ 12.8G`。用 `NSImage(size:flipped:drawingHandler:)` 而不是 lockFocus：
    /// 绘制闭包会**按屏幕缩放各画一份**（2x 屏上字不发虚）。
    static func cpuMemoryImage(cpu: Double, memoryGB: Double) -> NSImage {
        let cpuText = String(format: "%.0f%%", cpu)
        let memoryText = String(format: "%.1fG", memoryGB)
        let key = cpuText + "|" + memoryText
        if key == cacheKey, let cached { return cached }

        // 字号贴着系统菜单栏文字；等宽数字，避免数值跳动时整条宽度抖
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let cpuSize = (cpuText as NSString).size(withAttributes: attributes)
        let memorySize = (memoryText as NSString).size(withAttributes: attributes)
        let gap: CGFloat = 4, dividerWidth: CGFloat = 1, padding: CGFloat = 1

        let width = padding + cpuSize.width + gap + dividerWidth + gap + memorySize.width + padding
        let height = ceil(max(cpuSize.height, memorySize.height))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            let y = (rect.height - cpuSize.height) / 2
            (cpuText as NSString).draw(at: NSPoint(x: padding, y: y), withAttributes: attributes)
            let dividerX = padding + cpuSize.width + gap
            // 模板图靠 alpha 上色：分隔线用半透明画，系统会把它渲染成淡一档的同色
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSRect(x: dividerX, y: rect.height * 0.16, width: dividerWidth, height: rect.height * 0.68).fill()
            (memoryText as NSString).draw(at: NSPoint(x: dividerX + dividerWidth + gap, y: y),
                                          withAttributes: attributes)
            return true
        }
        image.isTemplate = true   // 由系统按菜单栏明暗自动上色
        cacheKey = key
        cached = image
        return image
    }
}
