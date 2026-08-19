//
//  DockEventMonitor.swift
//  DockZoom
//
//  Dock 图标点击监听：CGEventTap（会话级 + headInsert，先于系统处理）
//  + Dock 图标 AX 缓存命中 + AXUIElementCopyElementAtPosition 实时兜底。
//  决策在 10ms「保险箱」内完成，超时放行事件，绝不卡死输入链路。
//

import Cocoa
import ApplicationServices

func dockEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    return DockEventMonitor.shared.handleTapEvent(proxy: proxy, type: type, event: event)
}

final class DockEventMonitor {
    static let shared = DockEventMonitor()

    /// 点击 Dock 图标时回调；返回 true 表示本工具已接管（吞掉该事件）
    var onClick: ((NSRunningApplication, Bool) -> Bool)?   // (app, isWeChatHelper)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let workQueue = DispatchQueue(label: "com.dockzoom.dockevent", qos: .userInteractive)
    private let iconCache = DockIconCache()

    // 连击防抖（防抖期间静默吞掉，绝不放行给系统）
    private var lastClickPID: pid_t = -1
    private var lastClickTime: TimeInterval = 0
    private let clickDebounce: TimeInterval = 0.25

    // MARK: - 生命周期

    func start() {
        guard eventTap == nil else { return }
        iconCache.start()
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dockEventTapCallback,
            userInfo: nil
        ) else {
            DebugLogger.shared.log("EventTap 创建失败（需辅助功能权限）")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.shared.log("DockEventMonitor 已启动")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        iconCache.stop()
    }

    /// 健康检查：tap 被系统禁用后重建
    func ensureEnabled() {
        guard AccessibilityManager.shared.isActuallyWorking() else { return }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            DebugLogger.shared.log("EventTap 被系统禁用，正在重建")
            stop()
            start()
        } else if eventTap == nil {
            start()
        }
    }

    // MARK: - 事件处理

    func handleTapEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }

        let location = event.location

        // 1. Dock 区域几何预检
        guard isInDockZone(location) else { return Unmanaged.passUnretained(event) }

        // 2. 反查被点击的 Dock 图标 → 目标应用（未命中 = 文件夹/废纸篓/未运行 → 放行）
        guard let (app, isHelper) = resolveClickedApp(at: location) else {
            return Unmanaged.passUnretained(event)
        }

        // 3. O(1) 意图决策（后台快照，无耗时调用）
        let action = WindowStateTracker.shared.quickAction(for: app)
        if action == .none {
            // 无窗口可操作：放行交系统默认（例如 Reopen 打开新窗口）
            return Unmanaged.passUnretained(event)
        }

        // 4. 已解析到运行中的应用图标 → 事件由本工具完全接管，绝不放行给系统，
        //    杜绝"系统也执行一步"的双重行为（超时放行/防抖放行都会触发系统 Reopen）
        let now = Date().timeIntervalSince1970
        if app.processIdentifier == lastClickPID && now - lastClickTime < clickDebounce {
            return nil   // 快速连击：静默丢弃（第一击的动作正在执行）
        }
        lastClickPID = app.processIdentifier
        lastClickTime = now

        DebugLogger.shared.log("点击接管: app=\(app.localizedName ?? "?") helper=\(isHelper) 意图=\(action)")

        workQueue.async {
            WindowManager.shared.handleDockClick(app: app, isWeChatHelper: isHelper)
        }
        return nil
    }

    // MARK: - Dock 区域判定

    private func isInDockZone(_ cgPoint: CGPoint) -> Bool {
        let akPoint = ScreenLocator.appKitPoint(fromCGGlobal: cgPoint)
        guard let screen = ScreenLocator.screenContainingCG(point: cgPoint) else { return false }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let pos = DockPositionManager.shared.position(for: screen)
        let thickness = max(DockPositionManager.shared.realDockThickness(for: screen), 0)
        // 检测带宽：真实厚度 + 100px 余量（兼容图标放大溢出）；自动隐藏时厚度为 0，用固定带
        let band = max(thickness, 1) + 100

        switch pos {
        case .bottom:
            return akPoint.y >= frame.minY - 2 && akPoint.y <= frame.minY + band
                && akPoint.x >= frame.minX - 2 && akPoint.x <= frame.maxX + 2
        case .left:
            return akPoint.x >= frame.minX - 2 && akPoint.x <= frame.minX + band
                && akPoint.y >= frame.minY && akPoint.y <= visible.maxY   // 排除顶部菜单栏
        case .right:
            return akPoint.x <= frame.maxX + 2 && akPoint.x >= frame.maxX - band
                && akPoint.y >= frame.minY && akPoint.y <= visible.maxY
        }
    }

    // MARK: - 图标反查

    /// 对外暴露：缓存图标命中（供悬停预览使用）
    func hitTestIcon(at cgPoint: CGPoint) -> DockIconCache.DockIcon? {
        iconCache.hitTest(cgPoint)
    }

    /// 对外暴露：是否在 Dock 区域（供悬停预览的保持显示判断）
    func isInDockRegion(_ cgPoint: CGPoint) -> Bool {
        isInDockZone(cgPoint)
    }

    /// 对外暴露：强制刷新图标缓存（Dock 布局变化时）
    func refreshIconCache() {
        iconCache.refreshNow()
    }

    private func resolveClickedApp(at cgPoint: CGPoint) -> (NSRunningApplication, Bool)? {
        // 1) 缓存命中（快路径）
        if let icon = iconCache.hitTest(cgPoint) {
            if let app = app(for: icon.fileURL, title: icon.title) {
                return (app, WeChatHandler.isHelperURL(icon.fileURL))
            }
        }
        // 2) AX 实时命中（自动隐藏 Dock / 缓存滞后的兜底）
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &element)
        guard err == .success, let el = element, isDockIconElement(el) else { return nil }
        let url = WindowThumbnailService.shared.axGet(el, kAXURLAttribute).1 as? URL
        let title = WindowThumbnailService.shared.axGet(el, kAXTitleAttribute).1 as? String
        guard let app = app(for: url, title: title) else { return nil }
        return (app, WeChatHandler.isHelperURL(url))
    }

    /// 判断 AX 元素是否为 Dock 图标（role 或父 role 为 AXDockItem）
    private func isDockIconElement(_ element: AXUIElement) -> Bool {
        let role = WindowThumbnailService.shared.axGet(element, kAXRoleAttribute).1 as? String
        if role == "AXDockItem" { return true }
        if let rawParent = WindowThumbnailService.shared.axGet(element, kAXParentAttribute).1 {
            let parent = rawParent as! AXUIElement
            let parentRole = WindowThumbnailService.shared.axGet(parent, kAXRoleAttribute).1 as? String
            if parentRole == "AXDockItem" { return true }
        }
        return false
    }

    private func app(for fileURL: URL?, title: String?) -> NSRunningApplication? {
        let apps = RunningAppsCache.shared.apps()
        // 微信辅助进程（文章/小程序）：Dock 图标 URL 是 WeChatAppEx.app，映射回微信主应用
        if let fileURL, WeChatHandler.isHelperURL(fileURL),
           let wechat = apps.first(where: { $0.bundleIdentifier == WeChatHandler.mainBundleID }) {
            return wechat
        }
        if let fileURL, let match = apps.first(where: { $0.bundleURL == fileURL }) {
            return match
        }
        // 标题模糊匹配兜底
        if let title, !title.isEmpty,
           let match = apps.first(where: { app in
               guard let name = app.localizedName else { return false }
               return name == title || name.contains(title) || title.contains(name)
           }) {
            return match
        }
        return nil
    }
}

// MARK: - Dock 图标缓存

final class DockIconCache {
    struct DockIcon {
        var rect: CGRect       // CG 全局坐标（左上原点）
        var title: String
        var fileURL: URL?
        var isApp: Bool
    }

    private var icons: [DockIcon] = []
    private let lock = NSLock()
    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "com.dockzoom.dockicons", qos: .utility)

    func start() {
        guard timer == nil else { return }
        refreshQueue.async { [weak self] in self?.refresh() }
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshQueue.async { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func hitTest(_ point: CGPoint) -> DockIcon? {
        lock.lock()
        defer { lock.unlock() }
        return icons.first { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }
    }

    func refreshNow() {
        refreshQueue.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard AccessibilityManager.shared.isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        let service = WindowThumbnailService.shared
        let dockRef = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockRef, 1.0)

        guard let children = service.axGet(dockRef, kAXChildrenAttribute).1 as? [AXUIElement] else { return }

        var newIcons: [DockIcon] = []
        for child in children {
            guard let role = service.axGet(child, kAXRoleAttribute).1 as? String,
                  role == kAXListRole else { continue }
            guard let items = service.axGet(child, kAXChildrenAttribute).1 as? [AXUIElement] else { continue }
            for item in items {
                guard let p = service.axCGPoint(service.axGet(item, kAXPositionAttribute).1),
                      let s = service.axCGSize(service.axGet(item, kAXSizeAttribute).1) else { continue }
                let rect = CGRect(origin: p, size: s)
                let title = service.axGet(item, kAXTitleAttribute).1 as? String ?? ""
                let url = service.axGet(item, kAXURLAttribute).1 as? URL
                let subrole = service.axGet(item, kAXSubroleAttribute).1 as? String ?? ""

                // 过滤非应用图标：
                // macOS 26+ 的 Dock 中所有图标（含文件夹/分隔符/废纸篓）的 role 都是 AXDockItem，
                // 只有 subrole == AXApplicationDockItem 才是应用图标（诊断实测）
                let isAppIcon = subrole == "AXApplicationDockItem"
                    || url?.pathExtension == "app"

                if isAppIcon {
                    newIcons.append(DockIcon(rect: rect, title: title, fileURL: url, isApp: true))
                }
            }
        }
        lock.lock()
        icons = newIcons
        lock.unlock()
    }
}
