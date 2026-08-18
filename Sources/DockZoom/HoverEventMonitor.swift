//
//  HoverEventMonitor.swift
//  DockZoom
//
//  Dock 图标悬停监听：mouseMoved（listenOnly，40ms 节流）→ 图标缓存命中 → 预览条。
//

import Cocoa

func hoverEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    HoverEventMonitor.shared.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class HoverEventMonitor {
    static let shared = HoverEventMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastHandled: TimeInterval = 0
    /// 重入保护：回调内禁止再次进入（NSWindow 创建会泵事件，防止 dispatch_once 重入崩溃）
    private var isHandling = false

    // 悬停延迟显示状态（图标上连续停留 hoverDelay 秒后才弹预览）
    private var hoveredPID: pid_t = -1
    private var hoverStart: TimeInterval = 0
    private var previewShown = false
    private let hoverDelay: TimeInterval = 0.5

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hoverEventTapCallback,
            userInfo: nil
        ) else {
            DebugLogger.shared.log("悬停监听 EventTap 创建失败")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.shared.log("HoverEventMonitor 已启动")
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
    }

    func handleEvent(type: CGEventType, event: CGEvent) {
        guard type == .mouseMoved, !isHandling else { return }
        isHandling = true
        defer { isHandling = false }
        guard SettingsManager.shared.hoverPreviewEnabled else {
            PreviewBarController.shared.hide()
            return
        }
        let now = Date().timeIntervalSince1970
        guard now - lastHandled > 0.04 else { return }
        lastHandled = now

        let location = event.location
        guard let icon = DockEventMonitor.shared.hitTestIcon(at: location),
              let app = app(for: icon) else {
            // 离开图标：重置悬停状态，交给预览条做离开判定
            hoveredPID = -1
            previewShown = false
            PreviewBarController.shared.mouseMovedOutside(point: location)
            return
        }

        // 黑名单应用不弹预览
        if let bundleID = app.bundleIdentifier,
           SettingsManager.shared.shouldSkipDockHandling(bundleID: bundleID) {
            hoveredPID = -1
            previewShown = false
            PreviewBarController.shared.hide()
            return
        }

        // 换图标 → 重新计时 + 立即预取窗口（0.5s 到期瞬间出条）
        if app.processIdentifier != hoveredPID {
            hoveredPID = app.processIdentifier
            hoverStart = now
            previewShown = false
            PreviewBarController.shared.prefetch(for: app)
        }
        // 连续停留满 hoverDelay 才显示
        if !previewShown, now - hoverStart >= hoverDelay {
            previewShown = true
            PreviewBarController.shared.show(for: app, iconRect: icon.rect, mouse: location)
        }
    }

    private func app(for icon: DockIconCache.DockIcon) -> NSRunningApplication? {
        let apps = RunningAppsCache.shared.apps()
        // 微信辅助进程图标 → 主微信
        if let url = icon.fileURL, WeChatHandler.isHelperURL(url),
           let wechat = apps.first(where: { $0.bundleIdentifier == WeChatHandler.mainBundleID }) {
            return wechat
        }
        if let url = icon.fileURL,
           let match = apps.first(where: { $0.bundleURL == url }) {
            return match
        }
        if !icon.title.isEmpty,
           let match = apps.first(where: { $0.localizedName == icon.title }) {
            return match
        }
        return nil
    }
}
