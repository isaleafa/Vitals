#!/usr/bin/env swift
//
// 生成 Vitals 的应用图标（不依赖设计文件，纯代码画，随时可重跑）。
//   swift scripts/make-icon.swift <输出的 .iconset 目录>
// 设计：深蓝夜色底 + 薄荷色心电波形 —— "生命体征 / 脉诊"，16px 下也认得出。
//
// 注意：不用 NSImage.lockFocus（在 Retina 上会按 2x 渲染，1024 的图变成 2048）；
// 这里显式建位图，像素尺寸精确可控。
//
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("用法: swift make-icon.swift <输出 .iconset 目录>")
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

/// 在一块 `pixels × pixels` 的位图上画图标（内部坐标按 1024 比例缩放）。
func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    let s = size / 1024
    let cg = context.cgContext

    // macOS 图标网格：圆角方块约占画布 82%
    let inset = 92 * s
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底色 + 投影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 26 * s,
                 color: NSColor.black.withAlphaComponent(0.32).cgColor)
    NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.16, alpha: 1).setFill()
    squircle.fill()
    cg.restoreGState()

    // 渐变（上亮下暗）+ 淡淡横向网格
    cg.saveGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.11, green: 0.21, blue: 0.36, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.13, alpha: 1),
    ])?.draw(in: rect, angle: -90)
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.10),
        NSColor.white.withAlphaComponent(0.0),
    ])?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSColor.white.withAlphaComponent(0.06).setStroke()
    for index in 1..<5 {
        let y = rect.minY + rect.height * CGFloat(index) / 5
        let line = NSBezierPath()
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.line(to: CGPoint(x: rect.maxX, y: y))
        line.lineWidth = 2 * s
        line.stroke()
    }
    cg.restoreGState()

    // 心电波形（先柔光后主线）
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
    let pulse = NSBezierPath()
    pulse.move(to: point(0.08, 0.50))
    pulse.line(to: point(0.30, 0.50))
    pulse.line(to: point(0.38, 0.57))
    pulse.line(to: point(0.46, 0.29))
    pulse.line(to: point(0.55, 0.75))
    pulse.line(to: point(0.63, 0.50))
    pulse.line(to: point(0.92, 0.50))
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round

    let mint = NSColor(calibratedRed: 0.33, green: 0.91, blue: 0.71, alpha: 1)
    pulse.lineWidth = 96 * s
    mint.withAlphaComponent(0.22).setStroke()
    pulse.stroke()
    pulse.lineWidth = 54 * s
    mint.setStroke()
    pulse.stroke()

    // 波形右端光点
    let end = point(0.92, 0.50)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: end.x - 26 * s, y: end.y - 26 * s, width: 52 * s, height: 52 * s)).fill()

    return rep.representation(using: .png, properties: [:])
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in entries {
    guard let data = render(pixels: pixels) else { continue }
    try? data.write(to: outputURL.appendingPathComponent("\(name).png"))
}
print("已生成 \(entries.count) 个尺寸 → \(outputURL.path)")
