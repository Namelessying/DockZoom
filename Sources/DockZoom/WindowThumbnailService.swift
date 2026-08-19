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
        // 默认 AX 超时 6s，挂死的应用会拖垮线程；降到 0.5s
        AXUIElementSetMessagingTimeout(appRef, 0.5)
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
            // ⚠️ 过滤僵尸条目：runningApplications 可能包含同 bundleID 的
            // 已终止对象（processIdentifier == -1），first(where:) 命中它会导致
            // 后续全部失效（Steam 等会重启进程的应用点击无反应的根因）
            cached = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier > 0 && !$0.isTerminated
            }
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

// MARK: - Dock 图标 → 应用解析（多进程同名 bundle 时选主进程）

extension RunningAppsCache {
    /// 从 Dock 图标反查应用（解决多进程/嵌套 bundle 应用，如 Steam）：
    ///  1. 微信辅助进程图标 → 主微信
    ///  2. 用图标 .app 的 bundleIdentifier 匹配进程（最可靠；Steam 主程序 steam_osx 的
    ///     bundleURL 是嵌套 AppBundle 路径，且不出现在 runningApplications 列表中，
    ///     需用 proc_listpids 全量扫描进程表找回）
    ///  3. bundleURL 严格匹配兜底
    ///  找不到主进程时返回 nil → 点击放行给系统（系统的 LaunchServices 解析是准的，
    ///     绝不要用标题模糊匹配，它会命中 Helper 进程）
    static func bestMatch(for fileURL: URL?, title: String?) -> NSRunningApplication? {
        let apps = shared.apps()

        // 微信辅助进程图标 → 主微信
        if let url = fileURL, WeChatHandler.isHelperURL(url),
           let wechat = apps.first(where: { $0.bundleIdentifier == WeChatHandler.mainBundleID }) {
            return wechat
        }

        func prefer(_ pool: [NSRunningApplication]) -> NSRunningApplication? {
            guard !pool.isEmpty else { return nil }
            if let t = title, !t.isEmpty,
               let exact = pool.first(where: { $0.localizedName == t && $0.activationPolicy == .regular }) {
                return exact
            }
            if let t = title, !t.isEmpty,
               let exact = pool.first(where: { $0.localizedName == t }) {
                return exact
            }
            if let regular = pool.first(where: { $0.activationPolicy == .regular }) {
                return regular
            }
            return pool.first
        }

        // 1) 图标 .app 的 bundleIdentifier 匹配（含进程表全量扫描兜底）
        if let url = fileURL,
           let iconBundle = Bundle(url: url),
           let bid = iconBundle.bundleIdentifier {
            var pool = apps.filter { $0.bundleIdentifier == bid }
            if pool.isEmpty, let pid = Self.findPID(byBundleID: bid),
               let app = NSRunningApplication(processIdentifier: pid) {
                pool = [app]
            }
            if let match = prefer(pool) {
                return match
            }
        }

        // 2) bundleURL 严格匹配兜底
        if let url = fileURL, let match = prefer(apps.filter { $0.bundleURL == url }) {
            return match
        }

        // 3) 找不到主进程：返回 nil（放行给系统），不做模糊匹配以免命中 Helper
        return nil
    }

    /// 全量扫描系统进程表，按 bundleIdentifier 找存活进程
    /// （Steam 主程序等嵌套 bundle 进程不会出现在 runningApplications 中）
    static func findPID(byBundleID bid: String) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listpids(1 /* PROC_ALL_PIDS */, 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        let count = min(Int(n) / MemoryLayout<pid_t>.size, pids.count)
        for i in 0..<count where pids[i] > 0 {
            if let app = NSRunningApplication(processIdentifier: pids[i]),
               app.bundleIdentifier == bid, !app.isTerminated {
                return pids[i]
            }
        }
        return nil
    }
}
