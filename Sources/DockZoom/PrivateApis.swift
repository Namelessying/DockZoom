//
//  PrivateApis.swift
//  DockZoom
//
//  私有 WindowServer/SkyLight API 声明。
//  这些函数名来自开源社区（DockDoor / DockMinimize(MIT) / Hammerspoon issue#370），
//  仅用于非 App Store 分发的增强功能；未开启沙盒。
//

import Cocoa

// MARK: - 私有窗口 API

/// 从 AXUIElement 获取对应的 CGWindowID（macOS 10.10+）
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: inout CGWindowID) -> AXError

// MARK: - 私有窗口截图选项

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// 私有截图：可截取最小化窗口、规避 Stage Manager 干扰（需要屏幕录制权限）
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(
    _ cid: CGSConnectionID,
    _ windowList: UnsafePointer<UInt32>,
    _ count: UInt32,
    _ options: CGSWindowCaptureOptions
) -> CFArray?

// MARK: - SkyLight 私有 API（窗口置前 / key window）

struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

private var skyLightHandle: UnsafeMutableRawPointer?
private var setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType?
private var postEventRecordPtr: SLPSPostEventRecordToType?

private func loadSkyLightFunctions() {
    guard skyLightHandle == nil else { return }
    let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(skyLightPath, RTLD_LAZY) else {
        NSLog("DockZoom: 无法加载 SkyLight 框架")
        return
    }
    skyLightHandle = handle
    if let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
        setFrontProcessPtr = unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
    }
    if let symbol = dlsym(handle, "SLPSPostEventRecordTo") {
        postEventRecordPtr = unsafeBitCast(symbol, to: SLPSPostEventRecordToType.self)
    }
}

func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ wid: CGWindowID,
    _ mode: SLPSMode.RawValue
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, wid, mode)
}

typealias SLPSPostEventRecordToType = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutablePointer<UInt8>
) -> CGError

func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = postEventRecordPtr else { return CGError(rawValue: -1)! }
    return fn(psn, bytes)
}

/// 用 SkyLight 私有 API 把窗口设为 key window（参考 Hammerspoon issue#370）
func makeKeyWindow(_ psn: inout ProcessSerialNumber, windowID: CGWindowID) {
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    var wid = UInt32(windowID)
    memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
    memset(&bytes[0x20], 0xFF, 0x10)
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}

/// 把指定进程的某个窗口置前并设为 key window
func bringWindowAppToFront(pid: pid_t, windowId: CGWindowID) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, SLPSMode.userGenerated.rawValue)
    makeKeyWindow(&psn, windowID: windowId)
}

// MARK: - Dock 位置检测

enum DockPosition {
    case bottom
    case left
    case right
}

final class DockPositionManager {
    static let shared = DockPositionManager()

    /// 是否启用放大效果（com.apple.dock magnification）
    private(set) var isMagnificationEnabled: Bool = false
    /// 静态图标边长（com.apple.dock tilesize）
    private(set) var dockTileSize: CGFloat = 64
    /// 放大后图标边长（com.apple.dock largesize）
    private(set) var dockLargeSize: CGFloat = 128

    /// 放大倍数：未启用返回 1.0，启用返回 largesize/tilesize（最小 1.0）
    var magnificationScale: CGFloat {
        guard isMagnificationEnabled else { return 1.0 }
        let tile = max(dockTileSize, 1)
        return max(1.0, dockLargeSize / tile)
    }

    private init() {
        loadDockPreferences()
        // 监听 Dock 偏好变更（用户在系统设置里改 Dock 大小/放大时实时刷新）
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(dockPreferencesChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"),
            object: nil
        )
    }

    @objc private func dockPreferencesChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.loadDockPreferences()
        }
    }

    func loadDockPreferences() {
        let appId = "com.apple.dock" as CFString
        if let value = CFPreferencesCopyAppValue("magnification" as CFString, appId) as? Bool {
            isMagnificationEnabled = value
        }
        if let value = CFPreferencesCopyAppValue("tilesize" as CFString, appId) as? CGFloat {
            dockTileSize = value
        } else if let value = CFPreferencesCopyAppValue("tilesize" as CFString, appId) as? Double {
            dockTileSize = CGFloat(value)
        }
        if let value = CFPreferencesCopyAppValue("largesize" as CFString, appId) as? CGFloat {
            dockLargeSize = value
        } else if let value = CFPreferencesCopyAppValue("largesize" as CFString, appId) as? Double {
            dockLargeSize = CGFloat(value)
        }
    }

    /// 指定屏幕上的 Dock 位置（通过 visibleFrame 与 frame 差值判断）
    func position(for screen: NSScreen?) -> DockPosition {
        guard let screen = screen else { return .bottom }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        if visibleFrame.origin.y > frame.origin.y + 0.5 { return .bottom }
        if visibleFrame.origin.x > frame.origin.x + 0.5 { return .left }
        if visibleFrame.size.width < frame.size.width - 0.5 { return .right }
        return .bottom
    }

    /// 指定屏幕上的 Dock 真实像素厚度
    func realDockThickness(for screen: NSScreen?) -> CGFloat {
        guard let screen = screen else { return 60 }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        switch position(for: screen) {
        case .bottom:
            return max(0, visibleFrame.origin.y - frame.origin.y)
        case .left:
            return max(0, visibleFrame.origin.x - frame.origin.x)
        case .right:
            let leftPad = visibleFrame.origin.x - frame.origin.x
            return max(0, frame.width - leftPad - visibleFrame.width)
        }
    }

    /// Dock 点击检测范围（比真实厚度略宽，兼容放大的图标溢出）
    var detectionThickness: CGFloat { 100 }
}

// MARK: - 屏幕坐标工具

/// EventTap 拿到的 CG 全局坐标（主屏左上为原点）与 AppKit 坐标（主屏左下为原点）互转
enum ScreenLocator {
    /// 主屏高度（用 CGMainDisplayID 而不是 NSScreen.screens.first，多显示器更可靠）
    private static var primaryCGHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func appKitPoint(fromCGGlobal cgPoint: CGPoint) -> CGPoint {
        CGPoint(x: cgPoint.x, y: primaryCGHeight - cgPoint.y)
    }

    static func cgPoint(fromAppKitGlobal akPoint: CGPoint) -> CGPoint {
        CGPoint(x: akPoint.x, y: primaryCGHeight - akPoint.y)
    }

    static func screenContainingCG(point cgPoint: CGPoint) -> NSScreen? {
        screenContainingAppKit(point: appKitPoint(fromCGGlobal: cgPoint))
    }

    static func screenContainingAppKit(point akPoint: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens where screen.frame.contains(akPoint) {
            return screen
        }
        // 屏幕缝隙：取最近的一块
        var closest: NSScreen?
        var closestDist = CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let dx = center.x - akPoint.x
            let dy = center.y - akPoint.y
            let dist = dx * dx + dy * dy
            if dist < closestDist {
                closestDist = dist
                closest = screen
            }
        }
        return closest ?? NSScreen.main
    }
}
