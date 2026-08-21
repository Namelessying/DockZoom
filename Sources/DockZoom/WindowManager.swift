//
//  WindowManager.swift
//  DockZoom
//
//  核心窗口管理：点击 Dock 图标 → 最小化（AX，系统播放原生 genie 动画）/ 恢复切换。
//  降级链：kAXMinimized → kAXHidden → NSRunningApplication.hide() → 合成 ⌘M。
//  特殊应用：Finder（永不 hide、AppleScript 恢复）、微信（主窗口/文章窗口区分、辅助进程）。
//

import Cocoa
import ApplicationServices

/// kAXFullscreenAttribute 未在公开常量中导出（参考 DockDoor / alt-tab-macos）
let kAXFullscreenAttribute = "AXFullScreen"

final class WindowManager {
    static let shared = WindowManager()

    private let service = WindowThumbnailService.shared
    private let workQueue = DispatchQueue(label: "com.dockzoom.windows", qos: .userInteractive)

    enum Source {
        case dockClick
        case hotkey
        case shake
    }

    // MARK: - 入口

    /// 点击 Dock 图标的总入口；返回 true 表示已接管（吞事件）
    @discardableResult
    func handleDockClick(app: NSRunningApplication, isWeChatHelper: Bool) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        if SettingsManager.shared.shouldSkipDockHandling(bundleID: bundleID) { return false }

        // 自身应用：直接最小化自己的窗口（注意 Bundle.main.bundleIdentifier 可能为 nil）
        if let ownID = Bundle.main.bundleIdentifier, bundleID == ownID {
            return handleSelfApp(app: app)
        }

        if isWeChatHelper {
            WeChatHandler.decideHelper(app: app)
            return true
        }
        if WeChatHandler.handles(bundleID) {
            if WeChatHandler.decide(app: app) { return true }
            // 快照与执行之间窗口可能已变化；事件已经被接管时至少复现系统激活语义。
            app.activate()
            return true
        }
        if FinderHandler.handles(bundleID) {
            if FinderHandler.decide(app: app) { return true }
            app.activate()
            return true
        }
        return decideGeneric(app: app)
    }

    /// 快捷键唤出/隐藏（跳过黑名单；未运行则启动）
    func toggleViaHotkey(bundleID: String) {
        let apps = RunningAppsCache.shared.apps()
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else {
            openApplication(bundleID: bundleID)
            return
        }
        if app.isHidden {
            workQueue.async {
                app.unhide()
                app.activate()
            }
            return
        }
        let windows = service.windows(for: app)
        let visible = service.visibleStandardWindows(windows)
        if app.isActive && !visible.isEmpty {
            workQueue.async { self.minimize(windows: visible, app: app) }
        } else {
            workQueue.async { self.restoreAll(windows: windows, app: app) }
        }
    }

    /// 后台队列执行入口（供 Handler 使用）
    func async(_ block: @escaping () -> Void) {
        workQueue.async(execute: block)
    }

    /// 预览条卡片点击：单窗口最小化/恢复切换（独立窗口控制）
    func toggleWindow(windowId: CGWindowID, app: NSRunningApplication) {
        workQueue.async {
            let windows = self.service.windows(for: app)
            guard let w = windows.first(where: { $0.windowId == windowId }) else { return }
            let isMinimized = self.service.axGet(w.axElement, kAXMinimizedAttribute).1 as? Bool ?? false
            if isMinimized {
                _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
                app.activate()
            } else {
                _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// 老板键：最小化所有应用窗口
    func minimizeAllWindows() {
        workQueue.async {
            let myPID = ProcessInfo.processInfo.processIdentifier
            for app in RunningAppsCache.shared.apps() where app.activationPolicy == .regular {
                if app.processIdentifier == myPID { continue }
                let windows = self.service.windows(for: app)
                let visible = self.service.visibleStandardWindows(windows)
                for w in visible {
                    _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
            DebugLogger.shared.log("老板键：已最小化所有窗口")
        }
    }

    // MARK: - 摇窗聚焦

    /// 摇窗聚焦快照（恢复用）
    private var shakeSnapshot: [(window: WindowThumbnailService.WindowInfo, app: NSRunningApplication)] = []
    private let snapshotLock = NSLock()

    /// 摇窗触发：有快照 → 恢复；无快照 → 最小化其它窗口并存快照
    func handleShake(shakenWindow: (pid: pid_t, windowId: CGWindowID)) {
        // 有快照 → 恢复
        snapshotLock.lock()
        if !shakeSnapshot.isEmpty {
            let snapshot = shakeSnapshot
            shakeSnapshot = []
            snapshotLock.unlock()
            restoreSnapshot(snapshot)
            return
        }
        snapshotLock.unlock()

        // 枚举放到后台队列（AX 调用可能阻塞，不能在事件回调主线程做）
        workQueue.async {
            var others: [(window: WindowThumbnailService.WindowInfo, app: NSRunningApplication)] = []
            for app in RunningAppsCache.shared.apps() where app.activationPolicy == .regular {
                let windows = self.service.windows(for: app)
                let visible = self.service.visibleStandardWindows(windows)
                for w in visible {
                    if app.processIdentifier == shakenWindow.pid && w.windowId == shakenWindow.windowId {
                        continue   // 保留被摇晃的窗口
                    }
                    others.append((window: w, app: app))
                }
            }
            guard !others.isEmpty else { return }

            for item in others {
                _ = AXUIElementSetAttributeValue(
                    item.window.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                )
            }
            self.snapshotLock.lock()
            self.shakeSnapshot = others
            self.snapshotLock.unlock()
            DebugLogger.shared.log("摇窗聚焦：已最小化 \(others.count) 个其它窗口")
        }
    }

    private func restoreSnapshot(
        _ snapshot: [(window: WindowThumbnailService.WindowInfo, app: NSRunningApplication)]
    ) {
        workQueue.async {
            // 先按应用 unhide + 激活
            var apps: [pid_t: NSRunningApplication] = [:]
            for item in snapshot {
                apps[item.app.processIdentifier] = item.app
            }
            for (_, app) in apps {
                if app.isHidden { app.unhide() }
                app.activate()
            }
            // 逐个反最小化
            for item in snapshot {
                _ = AXUIElementSetAttributeValue(
                    item.window.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse
                )
                Thread.sleep(forTimeInterval: 0.03)
            }
            DebugLogger.shared.log("摇窗聚焦：已恢复 \(snapshot.count) 个窗口")
        }
    }

    // MARK: - 通用决策

    /// 注意：事件已被 DockEventMonitor 接管后才会走到这里（QuickAction != .none）。
    /// 这里的返回值仅用于日志/语义，事件消费已由调用方保证。
    @discardableResult
    private func decideGeneric(app: NSRunningApplication) -> Bool {
        if app.isHidden {
            DebugLogger.shared.log("决策: \(app.localizedName ?? "?") 已隐藏 → 恢复显示")
            workQueue.async {
                app.unhide()
                app.activate()
                WindowStateTracker.shared.refreshNow(for: app)
            }
            return true
        }

        let windows = service.windows(for: app)
        let visible = service.visibleStandardWindows(windows)
        let minimized = service.minimizedWindows(windows)
        DebugLogger.shared.log("决策: \(app.localizedName ?? "?") isActive=\(app.isActive) 窗口=\(windows.count) 可见=\(visible.count) 最小化=\(minimized.count)")

        // 前台且窗口可见 → 最小化（原生 genie 动画）
        if app.isActive && !visible.isEmpty {
            workQueue.async { self.minimize(windows: visible, app: app) }
            return true
        }

        // 有最小化窗口且没有可见窗口 → 找回（GetBackMyWindows 语义：恢复全部最小化窗口）
        if visible.isEmpty && !minimized.isEmpty {
            workQueue.async { self.restoreAll(windows: windows, app: app) }
            return true
        }

        // AX 枚举为空但 CG 有可见窗口（部分应用不暴露 AX 窗口，如 Steam）
        // → 用 hide 切换（可逆且无需 AX；再点一次自动恢复显示）。
        // 不用 ⌘M：⌘M 最小化的窗口无法在无 AX 的情况下反向恢复。
        if windows.isEmpty && WindowStateTracker.shared.cgVisibleCount(for: app.processIdentifier) > 0 {
            DebugLogger.shared.log("决策: \(app.localizedName ?? "?") AX 无窗口但 CG 可见 → hide 兜底切换")
            workQueue.async {
                app.hide()
                WindowStateTracker.shared.refreshNow(for: app)
            }
            return true
        }

        // 其余（后台应用有可见窗口）→ 激活（事件已被接管，必须由我们自己执行）
        DebugLogger.shared.log("决策: \(app.localizedName ?? "?") → 激活")
        workQueue.async {
            app.activate()
            WindowStateTracker.shared.refreshNow(for: app)
        }
        return true
    }

    // MARK: - 最小化 / 恢复

    /// 最小化（AX → 系统播放 genie/scale；全屏窗口先退全屏）
    func minimize(windows: [WindowThumbnailService.WindowInfo], app: NSRunningApplication) {
        // 全屏窗口：先退全屏，等动画结束后再最小化（否则请求被静默忽略）
        var hasFullscreen = false
        for w in windows {
            if service.axGet(w.axElement, kAXFullscreenAttribute).1 as? Bool == true {
                AXUIElementSetAttributeValue(w.axElement, kAXFullscreenAttribute as CFString, kCFBooleanFalse)
                hasFullscreen = true
            }
        }
        if hasFullscreen {
            Thread.sleep(forTimeInterval: 1.0)
        }

        var failures = 0
        for w in windows {
            let err = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if err != .success {
                failures += 1
                DebugLogger.shared.log("AX 最小化失败: windowId=\(w.windowId) (\(err))")
            }
        }
        if failures == windows.count && !windows.isEmpty {
            DebugLogger.shared.log("\(app.localizedName ?? "?") 全部窗口 AX 最小化失败，走降级链")
            fallbackMinimize(app: app)
        } else if failures > 0 {
            // 部分失败：等待动画后确认是否仍有可见窗口，有则整应用隐藏兜底
            Thread.sleep(forTimeInterval: 0.4)
            let remaining = service.visibleStandardWindows(service.windows(for: app))
            if !remaining.isEmpty {
                DebugLogger.shared.log("部分窗口最小化失败，剩余 \(remaining.count) 个 → hide 兜底")
                app.hide()
            }
        } else {
            DebugLogger.shared.log("最小化完成: \(app.localizedName ?? "?") 成功=\(windows.count - failures)/\(windows.count)")
        }
        // 等系统最小化动画结束后再采样，避免把过渡态写入快照。
        WindowThumbnailService.shared.invalidateWindowCache()
        WindowStateTracker.shared.refreshAfterWindowTransition(for: app)
    }

    /// 降级链：kAXHidden → hide() → 合成 ⌘M
    func fallbackMinimize(app: NSRunningApplication) {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        let err = AXUIElementSetAttributeValue(appRef, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        if err == .success {
            DebugLogger.shared.log("降级: kAXHidden 成功")
            return
        }
        if app.hide() {
            DebugLogger.shared.log("降级: NSRunningApplication.hide() 成功")
            return
        }
        // 合成 ⌘M 前确认目标应用仍是前台，避免误伤其它应用
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            DebugLogger.shared.log("降级终止: 目标应用已不在前台，跳过 ⌘M")
            return
        }
        DebugLogger.shared.log("降级: 合成 ⌘M")
        synthesizeCommandM()
    }

    /// 恢复全部窗口：unhide + activate + 逐个反最小化 + raise
    func restoreAll(windows: [WindowThumbnailService.WindowInfo], app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate()

        let minimized = service.minimizedWindows(windows)
        if minimized.isEmpty {
            // 已经全部恢复：仅激活
            WindowStateTracker.shared.refreshNow(for: app)
            return
        }
        for (index, w) in minimized.enumerated() {
            _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
            if index < minimized.count - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        WindowThumbnailService.shared.invalidateWindowCache()
        WindowStateTracker.shared.refreshAfterWindowTransition(for: app)
    }

    // MARK: - 自身应用

    private func handleSelfApp(app: NSRunningApplication) -> Bool {
        let windows = service.windows(for: app)
        let visible = service.visibleStandardWindows(windows)
        if !visible.isEmpty {
            // 自身窗口用 AppKit miniaturize（必须主线程），也走原生 genie
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && !window.isMiniaturized {
                    window.miniaturize(nil)
                }
            }
            return true
        }
        return false
    }

    // MARK: - 工具

    private func openApplication(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    DebugLogger.shared.log("启动 \(bundleID) 失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 合成 ⌘M（最后兜底，仍走系统最小化路径 → 保留 genie）
    func synthesizeCommandM() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let kVK_ANSI_M: CGKeyCode = 0x2E
        let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_M, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_M, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Finder 特殊处理
//
// 不变量（来自 DockMinimize 的 FinderSpecialHandler 经验）：
//  I1. Finder 永不调 app.hide()/unhide()（桌面也是它的窗口，hide 会让桌面消失）
//  I2. Finder 多窗口反最小化在动画期间会冻结同进程 AX 写入 → 用 AppleScript 一次恢复
//  I3. Finder 不参与 reopenApplication（系统 reopen 会新开 Finder 窗口）

enum FinderHandler {
    static func handles(_ bundleID: String) -> Bool {
        bundleID == "com.apple.finder"
    }

    @discardableResult
    static func decide(app: NSRunningApplication) -> Bool {
        let service = WindowThumbnailService.shared
        let windows = service.windows(for: app)
        let visible = service.visibleStandardWindows(windows)
        let minimized = service.minimizedWindows(windows)

        if app.isActive && !visible.isEmpty {
            WindowManager.shared.async {
                WindowManager.shared.minimize(windows: visible, app: app)
            }
            return true
        }
        if visible.isEmpty && !minimized.isEmpty {
            WindowManager.shared.async { restoreAllFinder(minimized: minimized, app: app) }
            return true
        }
        return false
    }

    static func restoreAllFinder(
        minimized: [WindowThumbnailService.WindowInfo],
        app: NSRunningApplication
    ) {
        // 单窗口：直接 AX 恢复（避免 AppleScript 首次授权弹窗卡顿）
        if minimized.count <= 1 {
            app.activate()
            for w in minimized.reversed() {
                _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
            }
            WindowThumbnailService.shared.invalidateWindowCache()
            WindowStateTracker.shared.refreshAfterWindowTransition(for: app)
            return
        }
        // 多窗口：AppleScript 一次恢复全部（带超时防止授权弹窗阻塞挂死）
        let source = """
        tell application "Finder"
            with timeout of 4 seconds
                set collapsed of every window to false
            end timeout
        end tell
        """
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&errorDict)
        if errorDict == nil {
            app.activate()
            WindowThumbnailService.shared.invalidateWindowCache()
            WindowStateTracker.shared.refreshAfterWindowTransition(for: app)
            return
        }
        // 降级：AX 串行恢复
        app.activate()
        for w in minimized.reversed() {
            _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 0.12)
        }
        WindowThumbnailService.shared.invalidateWindowCache()
        WindowStateTracker.shared.refreshAfterWindowTransition(for: app)
    }
}

// MARK: - 微信特殊处理
//
// 经验（GetBackMyWindows + DockMinimize）：
//  W1. 微信有独立辅助进程 WeChatAppEx.app（文章/小程序窗口）
//  W2. 主聊天窗口标题为「微信/WeChat」，文章/小程序窗口标题不同
//  W3. 手动 AX 恢复比 app.activate 更稳定（企业微信同理）
//  W4. 过滤 280×380 搜索浮窗与 kCGWindowSharingState==0 僵尸窗口（已由 WindowThumbnailService 处理）

enum WeChatHandler {
    static let mainBundleID = "com.tencent.xinWeChat"

    static func handles(_ bundleID: String) -> Bool {
        bundleID == mainBundleID
    }

    static func isHelperURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString.contains("WeChatAppEx.app")
    }

    static func isMainChatTitle(_ title: String) -> Bool {
        title == "微信" || title == "WeChat" || title == "Weixin"
    }

    @discardableResult
    static func decide(app: NSRunningApplication) -> Bool {
        // hide 兜底后的下一次点击必须显式解隐；仅 activate/raise 对隐藏应用不可靠。
        if app.isHidden {
            WindowManager.shared.async {
                app.unhide()
                app.activate()
                WindowStateTracker.shared.refreshNow(for: app)
            }
            return true
        }

        let service = WindowThumbnailService.shared
        let windows = service.windows(for: app)
        let visible = service.visibleStandardWindows(windows)
        let minimized = service.minimizedWindows(windows)

        // 前台 + 可见 → 最小化（优先主聊天窗口；否则最小化焦点窗口；兜底全部）
        if app.isActive && !visible.isEmpty {
            let mainChat = visible.first(where: { isMainChatTitle($0.title) })
            WindowManager.shared.async {
                if let mainChat {
                    _ = AXUIElementSetAttributeValue(mainChat.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                } else {
                    WindowManager.shared.minimize(windows: visible, app: app)
                }
            }
            return true
        }

        // 无可见窗口但有最小化窗口 → 恢复（主聊天窗口优先）
        if visible.isEmpty && !minimized.isEmpty {
            WindowManager.shared.async {
                restoreWeChat(minimized: minimized, app: app)
            }
            return true
        }

        // 后台 → 找回主聊天窗口并激活
        if !app.isActive {
            WindowManager.shared.async {
                activateMainChat(windows: windows, app: app)
            }
            return true
        }

        // AX 无窗口但 CG 有可见窗口 → hide 兜底切换（同通用路径）
        if windows.isEmpty && WindowStateTracker.shared.cgVisibleCount(for: app.processIdentifier) > 0 {
            WindowManager.shared.async {
                app.hide()
                WindowStateTracker.shared.refreshNow(for: app)
            }
            return true
        }
        return false
    }

    /// 微信辅助进程（文章/小程序窗口）点击
    static func decideHelper(app: NSRunningApplication) {
        let service = WindowThumbnailService.shared
        let windows = service.windows(for: app)
        // 找「绿色窗口」：标题不是微信/WeChat（文章/小程序）
        let target = windows.first(where: { !$0.title.isEmpty && !isMainChatTitle($0.title) })
        WindowManager.shared.async {
            guard let target else {
                app.activate()
                return
            }
            let isMinimized = service.axGet(target.axElement, kAXMinimizedAttribute).1 as? Bool ?? false
            if isMinimized {
                _ = AXUIElementSetAttributeValue(target.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementPerformAction(target.axElement, kAXRaiseAction as CFString)
                app.activate()
            } else if app.isActive {
                _ = AXUIElementSetAttributeValue(target.axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            } else {
                _ = AXUIElementPerformAction(target.axElement, kAXRaiseAction as CFString)
                app.activate()
            }
        }
    }

    private static func restoreWeChat(
        minimized: [WindowThumbnailService.WindowInfo],
        app: NSRunningApplication
    ) {
        if app.isHidden { app.unhide() }
        // 主聊天窗口优先恢复
        let ordered = minimized.sorted { a, b in
            isMainChatTitle(a.title) && !isMainChatTitle(b.title)
        }
        for w in ordered {
            _ = AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
        }
        app.activate()
    }

    private static func activateMainChat(
        windows: [WindowThumbnailService.WindowInfo],
        app: NSRunningApplication
    ) {
        if let mainChat = windows.first(where: { isMainChatTitle($0.title) }) {
            let isMinimized = WindowThumbnailService.shared.axGet(mainChat.axElement, kAXMinimizedAttribute).1 as? Bool ?? false
            if isMinimized {
                _ = AXUIElementSetAttributeValue(mainChat.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = AXUIElementPerformAction(mainChat.axElement, kAXRaiseAction as CFString)
        }
        app.activate()
    }
}
