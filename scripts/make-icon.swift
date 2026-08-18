// 生成 DockZoom 应用图标（.iconset）
// 用法: swift make-icon.swift <iconset目录>
// 设计：蓝色渐变圆角底 + 白色窗口条 + 向下箭头（窗口落入 Dock 的意象）

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: make-icon.swift <iconset目录>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = args[1]

let sizes: [(points: Int, pixels: Int)] = [
    (16, 16), (16, 32), (32, 32), (32, 64),
    (128, 128), (128, 256), (256, 256), (256, 512),
    (512, 512), (512, 1024),
]

func drawIcon(pixel: Int) -> NSImage {
    let s = CGFloat(pixel)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    // 背景：蓝色渐变圆角矩形（macOS 图标规范圆角 ≈ 边长 22.37%）
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.38, green: 0.63, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.88, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    // 白色窗口条（上部）
    let barW = s * 0.44
    let barH = s * 0.32
    let bar = NSBezierPath(
        roundedRect: NSRect(x: (s - barW) / 2, y: s * 0.46, width: barW, height: barH),
        xRadius: barW * 0.16,
        yRadius: barW * 0.16
    )
    NSColor.white.setFill()
    bar.fill()

    // 窗口内两条「内容线」让窗口更可读
    let lineColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
    lineColor.setFill()
    let lineW = barW * 0.62
    for i in 0..<2 {
        let lineY = s * (0.66 - CGFloat(i) * 0.075)
        NSBezierPath(
            roundedRect: NSRect(x: (s - lineW) / 2, y: lineY, width: lineW, height: s * 0.028),
            xRadius: s * 0.014, yRadius: s * 0.014
        ).fill()
    }

    // 向下箭头（窗口落入 Dock）
    let arrow = NSBezierPath()
    let cx = s * 0.5
    let tipY = s * 0.14
    let baseY = s * 0.30
    let halfW = s * 0.10
    arrow.move(to: NSPoint(x: cx - halfW, y: baseY))
    arrow.line(to: NSPoint(x: cx, y: tipY))
    arrow.line(to: NSPoint(x: cx + halfW, y: baseY))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    return image
}

for entry in sizes {
    let image = drawIcon(pixel: entry.pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败: \(entry)\n".data(using: .utf8)!)
        exit(1)
    }
    let name = entry.points == entry.pixels
        ? "icon_\(entry.points)x\(entry.points).png"
        : "icon_\(entry.points)x\(entry.points)@2x.png"
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try! png.write(to: url)
}
print("图标已生成: \(outputDir)")
