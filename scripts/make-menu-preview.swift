// 生成 README 使用的菜单栏预览图，内容需与 MenuBarController.swift 保持一致。
import AppKit

let size = NSSize(width: 720, height: 584)
let image = NSImage(size: size)
image.lockFocus()

let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.82, green: 0.90, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.56, green: 0.72, blue: 0.94, alpha: 1),
])!
background.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// 菜单栏
NSColor(calibratedWhite: 0.98, alpha: 0.90).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 526, width: 720, height: 58)).fill()

let symbolConfig = NSImage.SymbolConfiguration(pointSize: 25, weight: .medium)
if let symbol = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockZoom")?.withSymbolConfiguration(symbolConfig) {
    symbol.draw(in: NSRect(x: 350, y: 540, width: 32, height: 28))
}

let statusStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
]
NSAttributedString(string: "80%   8月21日 周五  18:26", attributes: statusStyle)
    .draw(at: NSPoint(x: 406, y: 541))

// DockZoom 下拉菜单
let menuRect = NSRect(x: 138, y: 52, width: 444, height: 474)
let menuPath = NSBezierPath(roundedRect: menuRect, xRadius: 18, yRadius: 18)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 20
shadow.shadowOffset = NSSize(width: 0, height: -7)
shadow.set()
NSColor(calibratedWhite: 0.99, alpha: 0.96).setFill()
menuPath.fill()
NSGraphicsContext.restoreGraphicsState()

let itemStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
]
let secondaryStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1),
]

let items: [(String, String?)] = [
    ("偏好设置…", "⌘,"),
    ("暂停使用 DockZoom", nil),
    ("✓  开机自动启动", nil),
    ("检查更新", nil),
    ("打开日志目录", nil),
    ("退出 DockZoom", "⌘Q"),
]

var y: CGFloat = 465
for (index, item) in items.enumerated() {
    if index == 1 || index == 3 || index == 5 {
        NSColor(calibratedWhite: 0.72, alpha: 0.72).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 156, y: y + 19))
        separator.line(to: NSPoint(x: 564, y: y + 19))
        separator.lineWidth = 1
        separator.stroke()
        y -= 20
    }
    NSAttributedString(string: item.0, attributes: itemStyle).draw(at: NSPoint(x: 168, y: y))
    if let shortcut = item.1 {
        let attributed = NSAttributedString(string: shortcut, attributes: secondaryStyle)
        let width = attributed.size().width
        attributed.draw(at: NSPoint(x: 548 - width, y: y + 2))
    }
    y -= 66
}

image.unlockFocus()

guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("菜单预览图编码失败")
}
try png.write(to: URL(fileURLWithPath: "images/menu-bar.png"))
print("菜单栏预览图已生成: images/menu-bar.png")
