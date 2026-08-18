//
//  WindowThumbnailService.swift
//  DockZoom
//
//  窗口枚举与过滤：AX 窗口 + CGWindowList 双通道合并，
//  过滤僵尸窗口（kCGWindowSharingState == 0，微信/WPS/QQ音乐更新提示的鬼影窗口）、
//  浮窗（kAXFloatingWindowSubrole）与微信搜索浮窗（小尺寸）。
//

import Cocoa
import ApplicationServices

final class WindowThumbnailService {
    static let shared = WindowThumbnailService()
    private init() {}

    struct WindowInfo {
        let pid: pid_t
        let windowId: CGWindowID
        let title: String
        let axElement: AXUIElement
        let bounds: CGRect          // CG 全局坐标（左上原点）
        var isMinimized: Bool
        var isOnScreen: Bool
        var isFloating: Bool
        let layer: Int
        let sharingState: Int
    }

    // MARK: - AX 工具

    @discardableResult
    func axGet(_ element: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return (err, value)
    }

    func axCGPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let value = value else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    func axCGSize(_ value: CFTypeRef?) -> CGSize? {
        guard let value = value else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    // MARK: - 窗口列表缓存（短 TTL，避免每次点击/悬停全量拉取 CGWindowList）

    private let listLock = NSLock()
    private var cachedAllList: [[String: Any]]?
    private var cachedAllAt: TimeInterval = 0
    private var cachedOnScreenList: [[String: Any]]?
    private var cachedOnScreenAt: TimeInterval = 0
    private let listTTL: TimeInterval = 0.4

    /// 窗口动作完成后调用：让下一次枚举拿到最新状态
    func invalidateWindowCache() {
        listLock.lock()
        cachedAllList = nil
        cachedOnScreenList = nil
        listLock.unlock()
    }

    private func allWindowList() -> [[String: Any]] {
        listLock.lock()
        let now = Date().timeIntervalSince1970
        if let cached = cachedAllList, now - cachedAllAt < listTTL {
            listLock.unlock()
            return cached
        }
        listLock.unlock()
        let fresh = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        listLock.lock()
        cachedAllList = fresh
        cachedAllAt = Date().timeIntervalSince1970
        listLock.unlock()
        return fresh
    }

    private func onScreenWindowList() -> [[String: Any]] {
        listLock.lock()
        let now = Date().timeIntervalSince1970
        if let cached = cachedOnScreenList, now - cachedOnScreenAt < listTTL {
            listLock.unlock()
            return cached
        }
        listLock.unlock()
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        let fresh = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        listLock.lock()
        cachedOnScreenList = fresh
        cachedOnScreenAt = Date().timeIntervalSince1970
        listLock.unlock()
        return fresh
    }

    // MARK: - 窗口枚举

    /// 枚举指定应用的所有真实窗口（AX + CG 合并过滤）
    func windows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axWindows = axWindowsForApp(pid)
        let cgInfo = cgWindowInfo(pid: pid)
        let onScreenIDs = onScreenWindowIDs(pid: pid)

        var results: [WindowInfo] = []

        for ax in axWindows {
            var wid: CGWindowID = 0
            let err = _AXUIElementGetWindow(ax, &wid)
            guard err == .success, wid != 0 else { continue }

            let title = (axGet(ax, kAXTitleAttribute).1 as? String) ?? ""
            let bounds = windowBounds(ax: ax, cg: cgInfo[wid])

            // 幽灵窗口过滤：仅过滤 1×1 无标题窗口。
            // ⚠️ kCGWindowSharingState 在 macOS 27 上对所有窗口都返回 0，
            // 不能再当作「僵尸窗口」标记（旧版 DockMinimize 的做法会误杀全部窗口）。
            if title.isEmpty && bounds.width <= 2 && bounds.height <= 2 {
                continue
            }

            let isMinimized = (axGet(ax, kAXMinimizedAttribute).1 as? Bool) ?? false
            let subrole = (axGet(ax, kAXSubroleAttribute).1 as? String) ?? ""
            let isFloating = subrole == kAXFloatingWindowSubrole

            results.append(WindowInfo(
                pid: pid,
                windowId: wid,
                title: title,
                axElement: ax,
                bounds: bounds,
                isMinimized: isMinimized,
                isOnScreen: onScreenIDs.contains(wid),
                isFloating: isFloating,
                layer: cgInfo[wid]?.layer ?? 0,
                sharingState: cgInfo[wid]?.sharingState ?? 1
            ))
        }
        return results
    }

    /// 可见（在屏且未最小化）的普通窗口（排除浮窗）
    func visibleStandardWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter { $0.isOnScreen && !$0.isMinimized && !$0.isFloating }
    }

    /// 已最小化到 Dock 的窗口
    func minimizedWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter { $0.isMinimized }
    }

    // MARK: - 私有

    private struct CGWindowEntry {
        var layer: Int = 0
        var bounds: CGRect = .zero
        var sharingState: Int = 1
    }

    private func axWindowsForApp(_ pid: pid_t) -> [AXUIElement] {
        let appRef = AXUIElementCreateApplication(pid)
        // 默认 AX 超时 6s，挂死的应用会拖垮线程；降到 1s
        AXUIElementSetMessagingTimeout(appRef, 1.0)
        let (err, value) = axGet(appRef, kAXWindowsAttribute)
        guard err == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private func cgWindowInfo(pid: pid_t) -> [CGWindowID: CGWindowEntry] {
        var map: [CGWindowID: CGWindowEntry] = [:]
        let list = allWindowList()
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let num = entry[kCGWindowNumber as String] as? Int else { continue }
            var info = CGWindowEntry()
            info.layer = entry[kCGWindowLayer as String] as? Int ?? 0
            if let dict = entry[kCGWindowBounds as String] as? [String: Any],
               let x = dict["X"] as? CGFloat, let y = dict["Y"] as? CGFloat,
               let w = dict["Width"] as? CGFloat, let h = dict["Height"] as? CGFloat {
                info.bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            info.sharingState = entry[kCGWindowSharingState as String] as? Int ?? 1
            map[CGWindowID(num)] = info
        }
        return map
    }

    private func onScreenWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        var set = Set<CGWindowID>()
        let list = onScreenWindowList()
        for entry in list {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let num = entry[kCGWindowNumber as String] as? Int else { continue }
            set.insert(CGWindowID(num))
        }
        return set
    }

    private func windowBounds(ax: AXUIElement, cg: CGWindowEntry?) -> CGRect {
        if let p = axCGPoint(axGet(ax, kAXPositionAttribute).1),
           let s = axCGSize(axGet(ax, kAXSizeAttribute).1) {
            return CGRect(origin: p, size: s)
        }
        return cg?.bounds ?? .zero
    }
}

// MARK: - 运行中应用列表缓存（短 TTL，供点击/悬停高频路径使用）

final class RunningAppsCache {
    static let shared = RunningAppsCache()

    private let lock = NSLock()
    private var cached: [NSRunningApplication] = []
    private var cachedAt: TimeInterval = 0
    private let ttl: TimeInterval = 2

    func apps() -> [NSRunningApplication] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if cached.isEmpty || now - cachedAt > ttl {
            cached = NSWorkspace.shared.runningApplications
            cachedAt = now
        }
        return cached
    }

    func invalidate() {
        lock.lock()
        cached = []
        cachedAt = 0
        lock.unlock()
    }
}
