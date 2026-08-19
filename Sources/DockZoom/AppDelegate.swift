//
//  AppDelegate.swift
//  DockZoom
//

import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, SettingsProvider {
    private lazy var menuBar = MenuBarController(settingsProvider: self)
    private var healthTimer: Timer?
    private var permissionTimer: Timer?
    private var hasShownStuckAlert = false
    private var permissionFailCycles = 0
    private(set) var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.shared.enabled = SettingsManager.shared.logEnabled
        DebugLogger.shared.log("DockZoom 启动 (v\(kDockZoomVersion))")
        installCrashHandlers()

        // 支持 --settings 启动参数：启动即打开设置面板（截图/演示/调试用）
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        // 支持 --fix-login-item 启动参数：重注册登录项（刷新系统设置里显示的版本信息）
        if CommandLine.arguments.contains("--fix-login-item") {
            SettingsManager.shared.setLaunchAtLogin(false)
            SettingsManager.shared.setLaunchAtLogin(true)
            DebugLogger.shared.log("登录项已重新注册")
        }

        // 防 App Nap：事件监听需要常驻
        _ = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Dock 点击事件监听"
        )

        if SettingsManager.shared.menuBarIconVisible {
            menuBar.install()
        }

        // 暂停/恢复：菜单栏点击回调
        menuBar.onTogglePause = { [weak self] in
            self?.setPaused(!(self?.isPaused ?? true))
        }

        // 菜单栏图标开关联动
        NotificationCenter.default.addObserver(
            forName: SettingsManager.menuBarIconChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if SettingsManager.shared.menuBarIconVisible {
                self.menuBar.install()
            } else {
                self.menuBar.uninstall()
            }
        }

        // 暂停快捷键（⌃⌥⇧⌘F13）触发
        NotificationCenter.default.addObserver(
            forName: SettingsManager.togglePauseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setPaused(!(self?.isPaused ?? true))
        }

        // 配套开关 App 的跨进程指令
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.dockzoom.togglePause"), object: nil, queue: .main) { [weak self] _ in
            self?.setPaused(!(self?.isPaused ?? true))
        }
        dnc.addObserver(forName: Notification.Name("com.dockzoom.quit"), object: nil, queue: .main) { _ in
            NSApp.terminate(nil)
        }

        // 首次运行自动开启开机自启（可在菜单栏或设置里关闭）
        if !SettingsManager.shared.launchAtLoginAutoTried {
            SettingsManager.shared.launchAtLoginAutoTried = true
            if !SettingsManager.shared.launchAtLoginEnabled {
                SettingsManager.shared.setLaunchAtLogin(true)
                DebugLogger.shared.log("首次运行：已自动开启开机自启动")
            }
        }

        // 权限引导：
        //  - 先静默检测"实际可用"（不弹任何窗）
        //  - 不可用才弹一次系统授权框（终身一次，之后只显示设置窗口等待用户处理）
        //  - 避免每次打开都打扰用户
        if SettingsManager.shared.paused {
            isPaused = true
            menuBar.setPausedState(true)
            HotkeyManager.shared.start()   // 暂停键与老板键保持可用
            DebugLogger.shared.log("上次会话处于暂停状态，保持暂停")
        } else if AccessibilityManager.shared.isActuallyWorking() {
            startMonitors()
        } else {
            if !SettingsManager.shared.hasPromptedAXPermission {
                SettingsManager.shared.hasPromptedAXPermission = true
                AccessibilityManager.shared.promptIfNeeded()
            }
            startPermissionWatch()
            SettingsWindowController.shared.show()
        }

        // 健康检查：每 30s 检查 EventTap
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            if AccessibilityManager.shared.isActuallyWorking() {
                DockEventMonitor.shared.ensureEnabled()
                if self.permissionTimer == nil {
                    self.startMonitors()
                }
            } else if self.permissionTimer == nil {
                self.startPermissionWatch()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockEventMonitor.shared.stop()
        ShakeMonitor.shared.stop()
        HoverEventMonitor.shared.stop()
        DebugLogger.shared.log("DockZoom 退出")
    }

    // MARK: - 暂停 / 恢复

    /// 暂停使用：点击拦截/悬停预览/摇窗全部失效，Dock 恢复系统默认行为
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        SettingsManager.shared.paused = paused
        if paused {
            DockEventMonitor.shared.stop()
            HoverEventMonitor.shared.stop()
            ShakeMonitor.shared.stop()
            PreviewBarController.shared.hide()
            menuBar.setPausedState(true)
            DebugLogger.shared.log("已暂停使用（点击/预览/摇窗恢复系统默认）")
        } else {
            menuBar.setPausedState(false)
            startMonitors()
            DebugLogger.shared.log("已恢复使用")
        }
    }

    // MARK: - 监听启动

    private func startMonitors() {
        guard !isPaused else { return }
        // 预热单例：在启动路径（而非事件回调内）完成 NSWindow 创建，
        // 避免 dispatch_once 在事件泵中重入崩溃
        _ = PreviewBarController.shared
        WindowStateTracker.shared.start()
        DockEventMonitor.shared.onClick = { app, isHelper in
            WindowManager.shared.handleDockClick(app: app, isWeChatHelper: isHelper)
        }
        DockEventMonitor.shared.start()
        ShakeMonitor.shared.start()
        HotkeyManager.shared.start()
        HoverEventMonitor.shared.start()
    }

    /// 权限状态自适应轮询（借鉴 DockMinimizer：未授权 1s、已授权 5s）
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionFailCycles = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AccessibilityManager.shared.isActuallyWorking() {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                DebugLogger.shared.log("辅助功能权限已授予")
                self.startMonitors()
                return
            }
            // 连续 3 秒无权限 → 弹一次明确的操作指引（每次运行最多一次）
            self.permissionFailCycles += 1
            if self.permissionFailCycles >= 3 && !self.hasShownStuckAlert {
                self.hasShownStuckAlert = true
                self.showPermissionHelp()
            }
        }
    }

    /// 无权限时的明确指引弹窗
    private func showPermissionHelp() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "DockZoom 需要「辅助功能」权限"
            alert.informativeText = """
            没有该权限 DockZoom 无法工作（点击拦截/悬停预览都会失效）。

            请在「系统设置 → 隐私与安全性 → 辅助功能」中：
            1. 若列表里有 DockZoom 且已勾选 → 先取消勾选，再重新勾选
               （或选中它点「-」移除，再点「+」重新添加）
            2. 若列表里没有 DockZoom → 点「+」，选择 /Applications/DockZoom.app

            授权后无需重启，功能会自动生效。
            """
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                AccessibilityManager.shared.openSettings()
            }
        }
    }

    // MARK: - SettingsProvider

    func openSettings() {
        if !AccessibilityManager.shared.isTrusted {
            AccessibilityManager.shared.openSettings()
            return
        }
        SettingsWindowController.shared.show()
    }

    func checkUpdates() {
        UpdateChecker.shared.check(manual: true)
    }

    // MARK: - 崩溃保护

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            DebugLogger.shared.log("未捕获异常: \(exception.name) \(exception.reason ?? "")")
        }
        // 记录信号 + 当前线程栈（写入 stderr 与日志），然后恢复默认处理并重抛，
        // 让系统正常生成崩溃报告（避免处理器吞掉信号后陷入重复 trap 循环）
        signal(SIGSEGV, dzSignalHandler)
        signal(SIGABRT, dzSignalHandler)
        signal(SIGBUS, dzSignalHandler)
        signal(SIGFPE, dzSignalHandler)
        signal(SIGILL, dzSignalHandler)
        signal(SIGTRAP, dzSignalHandler)
    }
}

/// 全局信号处理器（C 函数指针，不能捕获上下文）
private func dzSignalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGSEGV: name = "SIGSEGV"
    case SIGABRT: name = "SIGABRT"
    case SIGBUS: name = "SIGBUS"
    case SIGFPE: name = "SIGFPE"
    case SIGILL: name = "SIGILL"
    case SIGTRAP: name = "SIGTRAP"
    default: name = "信号\(sig)"
    }
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
    let count = Int(backtrace(&frames, 48))
    let framesDump = frames[0..<max(count, 0)].map { $0 == nil ? "0x0" : "\($0!)" }.joined(separator: " ")
    DebugLogger.shared.log("崩溃: \(name) 栈=[\(framesDump)]")
    backtrace_symbols_fd(&frames, Int32(count), STDERR_FILENO)
    signal(sig, SIG_DFL)
    raise(sig)
}
