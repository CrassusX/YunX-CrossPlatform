#!/usr/bin/env swift
// 生成应用图标：圆角渐变底 + 下载箭头。
// 直接在目标像素尺寸上绘制（不是缩放），保证 16px 下也不糊。

import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources"

let iconsetURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let topColor = NSColor(srgbRed: 0.376, green: 0.612, blue: 1.0, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.196, green: 0.298, blue: 0.906, alpha: 1)

func drawIcon(pixelSize: Int) -> Data {
    let side = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("无法创建位图")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS 图标规范：内容区留 10% 边距
    let inset = side * 0.085
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.225

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(starting: topColor, ending: bottomColor)
    gradient?.draw(in: path, angle: -90)

    // 顶部高光，让图标有体积感
    let highlight = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16).setFill()
    NSGraphicsContext.saveGraphicsState()
    highlight.addClip()
    NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // 下载箭头
    let unit = rect.width
    let strokeWidth = max(unit * 0.072, 1.2)
    let arrow = NSBezierPath()
    arrow.lineWidth = strokeWidth
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round

    let centerX = rect.midX
    let topY = rect.minY + unit * 0.70
    let bottomY = rect.minY + unit * 0.375

    arrow.move(to: NSPoint(x: centerX, y: topY))
    arrow.line(to: NSPoint(x: centerX, y: bottomY))

    arrow.move(to: NSPoint(x: centerX - unit * 0.145, y: rect.minY + unit * 0.505))
    arrow.line(to: NSPoint(x: centerX, y: bottomY))
    arrow.line(to: NSPoint(x: centerX + unit * 0.145, y: rect.minY + unit * 0.505))

    NSColor.white.setStroke()
    arrow.stroke()

    // 底部承托线
    let tray = NSBezierPath()
    tray.lineWidth = strokeWidth
    tray.lineCapStyle = .round
    tray.move(to: NSPoint(x: centerX - unit * 0.215, y: rect.minY + unit * 0.235))
    tray.line(to: NSPoint(x: centerX + unit * 0.215, y: rect.minY + unit * 0.235))
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9).setStroke()
    tray.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:]) ?? Data()
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    let data = drawIcon(pixelSize: variant.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(variant.name))
}

// 额外存一张 1024 给 README 用
try drawIcon(pixelSize: 1024)
    .write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon-1024.png"))

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns",
    iconsetURL.path,
    "-o", URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.icns").path
]
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0 ? "✅ AppIcon.icns 已生成" : "❌ iconutil 失败")
