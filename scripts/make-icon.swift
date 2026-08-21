// 生成 DockZoom 应用图标（.iconset）
// 用法: swift make-icon.swift <iconset目录> [icns输出路径]
// 设计：蓝色渐变圆角底 + 白色窗口 + genie 收束曲线（窗口缩入 Dock 的意象）

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: make-icon.swift <iconset目录> [icns输出路径]\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = args[1]

let sizes: [(points: Int, pixels: Int)] = [
    (16, 16), (16, 32), (32, 32), (32, 64),
    (48, 48),
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

    // 白色窗口（上部）
    let barW = s * 0.50
    let barH = s * 0.28
    let bar = NSBezierPath(
        roundedRect: NSRect(x: (s - barW) / 2, y: s * 0.56, width: barW, height: barH),
        xRadius: s * 0.055,
        yRadius: s * 0.055
    )
    NSColor.white.setFill()
    bar.fill()

    // 简洁标题栏，让白色主体在小尺寸下仍明确像一个 macOS 窗口。
    let detailColor = NSColor(calibratedRed: 0.16, green: 0.43, blue: 0.90, alpha: 0.30)
    detailColor.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: s * 0.275, y: s * 0.755, width: s * 0.45, height: max(1, s * 0.014)),
        xRadius: s * 0.007,
        yRadius: s * 0.007
    ).fill()
    for x in [CGFloat(0.30), 0.335, 0.37] {
        NSBezierPath(ovalIn: NSRect(x: s * x, y: s * 0.79, width: s * 0.018, height: s * 0.018)).fill()
    }

    // 两条收束曲线表达 macOS 的 genie 最小化动画，避免被误读为下载箭头。
    func drawGenieCurve(from start: NSPoint, to end: NSPoint, bend: CGFloat) {
        let curve = NSBezierPath()
        curve.move(to: start)
        curve.curve(
            to: end,
            controlPoint1: NSPoint(x: start.x + bend, y: s * 0.47),
            controlPoint2: NSPoint(x: end.x - bend * 0.25, y: s * 0.31)
        )
        curve.lineWidth = max(1.2, s * 0.058)
        curve.lineCapStyle = .round
        NSColor.white.setStroke()
        curve.stroke()
    }

    drawGenieCurve(
        from: NSPoint(x: s * 0.32, y: s * 0.55),
        to: NSPoint(x: s * 0.46, y: s * 0.24),
        bend: s * 0.04
    )
    drawGenieCurve(
        from: NSPoint(x: s * 0.68, y: s * 0.55),
        to: NSPoint(x: s * 0.54, y: s * 0.24),
        bend: -s * 0.04
    )

    // Dock 槽位
    let dockSlot = NSBezierPath(
        roundedRect: NSRect(x: s * 0.34, y: s * 0.145, width: s * 0.32, height: s * 0.075),
        xRadius: s * 0.038,
        yRadius: s * 0.038
    )
    NSColor.white.setFill()
    dockSlot.fill()

    return image
}

var pngByName: [String: Data] = [:]
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
    pngByName[name] = png
}

// macOS 预览版上的 iconutil 偶尔会把完整 iconset 误判为无效。
// 直接按公开 ICNS 容器格式封装 PNG，保证构建过程稳定且可复现。
if args.count >= 3 {
    let chunks: [(type: String, file: String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_48x48.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png"),
    ]

    func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    var payload = Data()
    for chunk in chunks {
        guard let png = pngByName[chunk.file] else { fatalError("缺少图标尺寸: \(chunk.file)") }
        payload.append(chunk.type.data(using: .ascii)!)
        appendUInt32BE(UInt32(png.count + 8), to: &payload)
        payload.append(png)
    }

    var icns = Data("icns".utf8)
    appendUInt32BE(UInt32(payload.count + 8), to: &icns)
    icns.append(payload)
    try! icns.write(to: URL(fileURLWithPath: args[2]))
    print("ICNS 已生成: \(args[2])")
}
print("图标已生成: \(outputDir)")
