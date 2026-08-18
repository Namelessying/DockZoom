// DockZoom 诊断工具：dump macOS Dock 的 AX 树与关键环境信息
// 用法: swift diag.swift
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: inout CGWindowID) -> AXError

func axGet(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
}

func describe(_ v: CFTypeRef?) -> String {
    guard let v else { return "-" }
    if let s = v as? String { return "\"\(s)\"" }
    if let b = v as? Bool { return b ? "true" : "false" }
    if let n = v as? NSNumber { return "\(n)" }
    if let url = v as? URL { return url.path }
    if let arr = v as? [AnyObject] { return "[\(arr.count) items]" }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        var p = CGPoint.zero
        if AXValueGetValue(v as! AXValue, .cgPoint, &p) { return "point(\(p.x), \(p.y))" }
        var s = CGSize.zero
        if AXValueGetValue(v as! AXValue, .cgSize, &s) { return "size(\(s.width), \(s.height))" }
        return "AXValue"
    }
    return "\(type(of: v)): \(v)"
}

print("=== 系统环境 ===")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")

print("\n=== Dock 偏好 (com.apple.dock) ===")
for key in ["magnification", "tilesize", "largesize", "autohide", "orientation", "pinch-to-zoom"] {
    if let v = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) {
        print("  \(key) = \(v)")
    } else {
        print("  \(key) = (默认/未设置)")
    }
}

print("\n=== 屏幕信息 ===")
for (i, screen) in NSScreen.screens.enumerated() {
    print("  屏\(i): frame=\(screen.frame) visibleFrame=\(screen.visibleFrame) 差值(bottom=\(screen.frame.minY - screen.visibleFrame.minY + screen.visibleFrame.minY - screen.frame.minY))")
    let f = screen.frame, v = screen.visibleFrame
    print("    底厚=\(String(format: "%.1f", v.minY - f.minY)) 左厚=\(String(format: "%.1f", v.minX - f.minX)) 右厚=\(String(format: "%.1f", f.maxX - v.maxX))")
}

print("\n=== Dock 进程 ===")
guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("  未找到 com.apple.dock!")
    exit(1)
}
print("  pid=\(dock.processIdentifier) name=\(dock.localizedName ?? "?")")

print("\n=== Dock AX 树（3 层）===")
let dockRef = AXUIElementCreateApplication(dock.processIdentifier)
AXUIElementSetMessagingTimeout(dockRef, 1.0)

func dumpElement(_ el: AXUIElement, indent: String, depth: Int) {
    guard depth > 0 else { return }
    let role = axGet(el, kAXRoleAttribute) as? String ?? "?"
    let subrole = axGet(el, kAXSubroleAttribute) as? String ?? "-"
    let title = axGet(el, kAXTitleAttribute) as? String ?? "-"
    let roleDesc = axGet(el, kAXRoleDescriptionAttribute) as? String ?? "-"
    let url = axGet(el, kAXURLAttribute) as? URL
    let pos = describe(axGet(el, kAXPositionAttribute))
    let size = describe(axGet(el, kAXSizeAttribute))
    print("\(indent)role=\(role) sub=\(subrole) title=\(title) roleDesc=\(roleDesc) url=\(url?.path ?? "-")")
    print("\(indent)   pos=\(pos) size=\(size)")
    if depth > 1, let children = axGet(el, kAXChildrenAttribute) as? [AXUIElement] {
        for (i, child) in children.enumerated() {
            if i >= 60 { print("\(indent)  …(更多 \(children.count - i) 项)"); break }
            dumpElement(child, indent: indent + "    ", depth: depth - 1)
        }
    }
}
dumpElement(dockRef, indent: "  ", depth: 3)

print("\n=== 前台应用 AX 窗口抽查 ===")
if let front = NSWorkspace.shared.frontmostApplication,
   front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
    print("  前台: \(front.localizedName ?? "?") pid=\(front.processIdentifier)")
    let ref = AXUIElementCreateApplication(front.processIdentifier)
    AXUIElementSetMessagingTimeout(ref, 1.0)
    if let windows = axGet(ref, kAXWindowsAttribute) as? [AXUIElement] {
        print("  kAXWindows 数量: \(windows.count)")
        for (i, w) in windows.prefix(8).enumerated() {
            let title = axGet(w, kAXTitleAttribute) as? String ?? "-"
            let role = axGet(w, kAXRoleAttribute) as? String ?? "?"
            let sub = axGet(w, kAXSubroleAttribute) as? String ?? "-"
            let minimized = axGet(w, kAXMinimizedAttribute) as? Bool
            var wid: CGWindowID = 0
            let widErr = _AXUIElementGetWindow(w, &wid)
            print("  窗\(i): title=\(title) role=\(role) sub=\(sub) minimized=\(String(describing: minimized)) wid=\(wid) widErr=\(widErr.rawValue)")
        }
    } else {
        print("  读不到 kAXWindows（该应用可能不支持 AX 或权限问题）")
    }
}

print("\n=== CGWindowList 抽查（前台应用）===")
if let front = NSWorkspace.shared.frontmostApplication,
   front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
    if let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
        var shown = 0
        for e in list {
            guard let pid = e[kCGWindowOwnerPID as String] as? Int32, pid == front.processIdentifier else { continue }
            guard shown < 10 else { break }
            shown += 1
            let layer = e[kCGWindowLayer as String] ?? "?"
            let num = e[kCGWindowNumber as String] ?? "?"
            let name = e[kCGWindowName as String] as? String ?? "-"
            let sharing = e[kCGWindowSharingState as String] ?? "?"
            let bounds = e[kCGWindowBounds as String] ?? "?"
            print("  win\(num) layer=\(layer) sharing=\(sharing) name=\(name) bounds=\(bounds)")
        }
    }
}
print("\n诊断完成")
