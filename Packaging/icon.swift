import AppKit

// Kairos 应用图标生成器：1024×1024 主图 → Packaging/AppIcon.png
// 设计：极光渐变（深靛蓝→紫→蓝）+ 中央柔光 + 白色对勾（Kairos 的核心动作「完成」）
//       + 底部一条发光细线（呼应非唤起态的计时光带）
// 用法：swift Packaging/icon.swift
let S = 1024
let size = NSSize(width: S, height: S)
let image = NSImage(size: size)
image.lockFocus()

// 背景：极光渐变（左上深靛蓝 → 右下蓝紫）
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.36, alpha: 1),
    NSColor(calibratedRed: 0.26, green: 0.15, blue: 0.48, alpha: 1),
    NSColor(calibratedRed: 0.38, green: 0.32, blue: 0.66, alpha: 1)
])!
bg.draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: 135)

// 中央柔光（accent 蓝，从中心向外淡出）
let accent = NSColor(calibratedRed: 0.51, green: 0.68, blue: 1.0, alpha: 1)
let glow = NSGradient(colors: [
    accent.withAlphaComponent(0.50),
    accent.withAlphaComponent(0.0)
])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 190, y: 250, width: 644, height: 644)),
          relativeCenterPosition: NSPoint(x: 0, y: 30))

// 暗角：四周略压，把视线收到中间
let vignette = NSGradient(colors: [
    NSColor(calibratedWhite: 0, alpha: 0.32),
    NSColor(calibratedWhite: 0, alpha: 0.0)
])!
vignette.draw(in: NSBezierPath(ovalIn: NSRect(x: -260, y: -260, width: S + 520, height: S + 520)),
              relativeCenterPosition: .zero)

// 白色对勾：Kairos 的核心动作「完成」，带柔光
let check = NSBezierPath()
check.move(to: NSPoint(x: 296, y: 548))
check.line(to: NSPoint(x: 452, y: 700))
check.line(to: NSPoint(x: 768, y: 342))
check.lineWidth = 96
check.lineCapStyle = .round
check.lineJoinStyle = .round
let checkShadow = NSShadow()
checkShadow.shadowColor = accent.withAlphaComponent(0.85)
checkShadow.shadowBlurRadius = 40
NSGraphicsContext.saveGraphicsState()
checkShadow.set()
NSColor.white.setStroke()
check.stroke()
NSGraphicsContext.restoreGraphicsState()

// 底部发光细线：呼应计时光带（从屏幕外照进来的光）
let bar = NSBezierPath(roundedRect: NSRect(x: 168, y: 96, width: 688, height: 16),
                       xRadius: 8, yRadius: 8)
let barShadow = NSShadow()
barShadow.shadowColor = accent.withAlphaComponent(0.9)
barShadow.shadowBlurRadius = 26
NSGraphicsContext.saveGraphicsState()
barShadow.set()
accent.setFill()
bar.fill()
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("生成 PNG 失败")
}
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Packaging/AppIcon.png")
try! png.write(to: out)
print("✅ 已生成 \(out.path)")
