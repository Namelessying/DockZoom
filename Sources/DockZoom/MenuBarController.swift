//
//  MenuBarController.swift
//  DockZoom
//

import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var settingsProvider: SettingsProvider?
    /// 暂停/恢复回调（由 AppDelegate 注入）
    var onTogglePause: (() -> Void)?
    private var pauseMenuItem: NSMenuItem?
    private var paused = false

    init(settingsProvider: SettingsProvider) {
        self.settingsProvider = settingsProvider
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = menuBarImage()
            button.toolTip = "DockZoom"
            // 左右键都弹同一个菜单（与 DockMinimize 一致）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.menu = buildMenu()
        statusItem = item
    }

    func uninstall() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// 更新暂停状态显示（图标 + 菜单项标题）
    func setPausedState(_ paused: Bool) {
        self.paused = paused
        statusItem?.button?.image = menuBarImage()
        pauseMenuItem?.title = paused ? "恢复使用 DockZoom" : "暂停使用 DockZoom"
        statusItem?.button?.toolTip = paused ? "DockZoom（已暂停）" : "DockZoom"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "偏好设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        let pauseItem = NSMenuItem(
            title: paused ? "恢复使用 DockZoom" : "暂停使用 DockZoom",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "检查更新",
            action: #selector(checkUpdates),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "打开日志目录",
            action: #selector(openLogs),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 DockZoom",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        for item in menu.items {
            item.target = self
        }
        menu.delegate = self
        return menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // 刷新开机自启动勾选状态
        let enabled = SettingsManager.shared.launchAtLoginEnabled
        for item in menu.items where item.action == #selector(toggleLaunchAtLogin) {
            item.state = enabled ? .on : .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !SettingsManager.shared.launchAtLoginEnabled
        SettingsManager.shared.setLaunchAtLogin(enable)
        DebugLogger.shared.log("开机自动启动: \(enable ? "开启" : "关闭")")
    }

    @objc private func openSettings() {
        settingsProvider?.openSettings()
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func checkUpdates() {
        settingsProvider?.checkUpdates()
    }

    @objc private func openLogs() {
        DebugLogger.shared.openLogDirectory()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuBarImage() -> NSImage {
        let symbol = paused ? "pause.circle.fill" : "dock.rectangle"
        if let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "DockZoom"
        ) {
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }
}

/// 菜单栏控制器与设置窗口/更新检查之间的解耦协议
protocol SettingsProvider: AnyObject {
    func openSettings()
    func checkUpdates()
}
