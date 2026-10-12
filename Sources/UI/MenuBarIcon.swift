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

    /// 判定是否为 100GB+ 内存的机器（如 128G/192G Mac Studio / Mac Pro），以决定三位数内存槽宽
    private static let isLargeMemory = ProcessInfo.processInfo.physicalMemory >= 100 * 1024 * 1024 * 1024

    /// `27% │ 12.8G`。用 `NSImage(size:flipped:drawingHandler:)` 而不是 lockFocus：
    /// 绘制闭包会**按屏幕缩放各画一份**（2x 屏上字不发虚）。
    ///
    /// 固定槽宽设计：
    /// 1. CPU 槽宽固定（容纳 0%~100%），数值靠右对齐（% 距分隔线间距恒定）。
    /// 2. 分隔线 X 坐标绝对固定。
    /// 3. 内存槽宽固定，数值靠左对齐（距分隔线间距恒定）。
    /// 4. 整图宽度固定，杜绝任何字符长短或数字变动引起的菜单栏横向抖动。
    static func cpuMemoryImage(cpu: Double, memoryGB: Double) -> NSImage {
        let cpuClamped = min(100, max(0, cpu))
        let cpuText = String(format: "%.0f%%", cpuClamped)
        let memoryText = String(format: "%.1fG", memoryGB)
        let key = cpuText + "|" + memoryText
        if key == cacheKey, let cached { return cached }

        // 字号贴着系统菜单栏文字；等宽数字
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let cpuSize = (cpuText as NSString).size(withAttributes: attributes)

        // 槽宽常数：
        // 12pt monospacedDigit: "100%" 宽 33.78pt -> cpuSlotWidth 取 34
        // 两位数 "99.9G" 宽 35.20pt -> memorySlotWidth 取 36 (100G+ 机器 "128.0G" 宽 42.76pt -> 取 43)
        let cpuSlotWidth: CGFloat = 34
        let memorySlotWidth: CGFloat = isLargeMemory ? 43 : 36
        let gap: CGFloat = 4, dividerWidth: CGFloat = 1, padding: CGFloat = 2

        let totalWidth = padding + cpuSlotWidth + gap + dividerWidth + gap + memorySlotWidth + padding
        let height = ceil(cpuSize.height)

        let dividerX = padding + cpuSlotWidth + gap
        let cpuX = padding + (cpuSlotWidth - cpuSize.width) // CPU 右对齐：紧靠分隔线左侧
        let memoryX = dividerX + dividerWidth + gap         // 内存左对齐：紧靠分隔线右侧

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            let y = (rect.height - cpuSize.height) / 2
            (cpuText as NSString).draw(at: NSPoint(x: cpuX, y: y), withAttributes: attributes)

            // 模板图靠 alpha 上色：分隔线用半透明画，系统会把它渲染成淡一档的同色
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSRect(x: dividerX, y: rect.height * 0.16, width: dividerWidth, height: rect.height * 0.68).fill()

            (memoryText as NSString).draw(at: NSPoint(x: memoryX, y: y), withAttributes: attributes)
            return true
        }
        image.isTemplate = true   // 由系统按菜单栏明暗自动上色
        cacheKey = key
        cached = image
        return image
    }
}
