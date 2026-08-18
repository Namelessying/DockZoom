//
//  SettingsManager.swift
//  DockZoom
//

import Foundation
import CoreGraphics
import ServiceManagement

/// 全局快捷键定义（可 Codable 持久化）
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt32   // CGEventFlags.rawValue
    var keyName: String = ""

    /// 显示字符串，如 ⌃A
    var displayString: String {
        var s = ""
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        if !keyName.isEmpty { return s + keyName }
        if keyCode >= 118 && keyCode <= 120 {   // F1-F20：F1=122, F2=120, F3=99…（简化：显示键码）
            return s + "F\(122 - Int(keyCode) + 1)"
        }
        return s + "键\(keyCode)"
    }
}

final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let blacklist = "blacklistedBundleIDs"
        static let hotkeys = "hotkeyBindings"
        static let hoverPreview = "hoverPreviewEnabled"
        static let independentWindowControl = "enableIndependentWindowControl"
        static let originalPreview = "enableOriginalPreview"
        static let focusPreview = "enableFocusPreview"
        static let previewStaysVisible = "previewStaysVisible"
        static let shakeToFocus = "shakeToFocusEnabled"
        static let menuBarIconVisible = "menuBarIconVisible"
        static let logEnabled = "logEnabled"
    }

    private init() {
        defaults.register(defaults: [
            Keys.hoverPreview: true,
            Keys.independentWindowControl: true,
            Keys.originalPreview: true,
            Keys.focusPreview: false,
            Keys.previewStaysVisible: false,
            Keys.shakeToFocus: true,
            Keys.menuBarIconVisible: true,
            Keys.logEnabled: true,
        ])
        // 默认老板键 ⌃A（只初始化一次，之后尊重用户设置）
        if !defaults.bool(forKey: "bossKeyInitialized") {
            defaults.set(true, forKey: "bossKeyInitialized")
            if hotkeyBindings[Self.bossKeyBundleID] == nil {
                setHotkey(KeyboardShortcut(keyCode: 0x00,
                                           modifiers: UInt32(CGEventFlags.maskControl.rawValue),
                                           keyName: "A"),
                          for: Self.bossKeyBundleID)
            }
        }
        // 默认暂停键 ⌃⌥⇧⌘F13（四修饰键组合，无任何软件/系统使用，几乎不可能误触）
        if !defaults.bool(forKey: "pauseKeyInitialized") {
            defaults.set(true, forKey: "pauseKeyInitialized")
            if hotkeyBindings[Self.pauseBundleID] == nil {
                // ⚠️ 修饰键位值必须用 SDK 枚举动态取（不同 SDK 位值不同，硬编码会坏）
                let allFour = CGEventFlags([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue
                setHotkey(KeyboardShortcut(keyCode: 0x69,
                                           modifiers: UInt32(allFour),
                                           keyName: "F13"),
                          for: Self.pauseBundleID)
            }
        }
    }

    /// 老板键（最小化所有窗口）的虚拟 bundleID
    static let bossKeyBundleID = "com.dockzoom.allapps"
    /// 暂停/恢复键的虚拟 bundleID
    static let pauseBundleID = "com.dockzoom.pause"

    static let menuBarIconChangedNotification = Notification.Name("DockZoomMenuBarIconChanged")
    /// 暂停/恢复通知（菜单栏与全局快捷键触发）
    static let togglePauseNotification = Notification.Name("DockZoomTogglePause")

    // MARK: - 暂停状态

    /// 是否暂停使用（点击拦截/悬停预览/摇窗全部失效，行为恢复系统默认）
    var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }

    /// 是否已弹过辅助功能授权请求（终身只弹一次系统授权框）
    var hasPromptedAXPermission: Bool {
        get { defaults.bool(forKey: "hasPromptedAXPermission") }
        set { defaults.set(newValue, forKey: "hasPromptedAXPermission") }
    }

    // MARK: - 黑名单

    var blacklistedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.blacklist) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.blacklist) }
    }

    func isBlacklisted(_ bundleID: String) -> Bool {
        blacklistedBundleIDs.contains(bundleID)
    }

    func addBlacklist(_ bundleID: String) {
        var set = blacklistedBundleIDs
        set.insert(bundleID)
        blacklistedBundleIDs = set
    }

    func removeBlacklist(_ bundleID: String) {
        var set = blacklistedBundleIDs
        set.remove(bundleID)
        blacklistedBundleIDs = set
    }

    /// 所有需要跳过 Dock 处理的应用（黑名单 + 自身）
    func shouldSkipDockHandling(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        if bundleID == Bundle.main.bundleIdentifier { return false }
        return isBlacklisted(bundleID)
    }

    // MARK: - 快捷键

    var hotkeyBindings: [String: KeyboardShortcut] {
        get {
            guard let data = defaults.data(forKey: Keys.hotkeys),
                  let dict = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hotkeys)
            }
        }
    }

    func hotkey(for bundleID: String) -> KeyboardShortcut? {
        hotkeyBindings[bundleID]
    }

    func setHotkey(_ shortcut: KeyboardShortcut?, for bundleID: String) {
        var bindings = hotkeyBindings
        bindings[bundleID] = shortcut
        hotkeyBindings = bindings
    }

    // MARK: - 功能开关

    var hoverPreviewEnabled: Bool {
        get { defaults.bool(forKey: Keys.hoverPreview) }
        set { defaults.set(newValue, forKey: Keys.hoverPreview) }
    }
    var enableIndependentWindowControl: Bool {
        get { defaults.bool(forKey: Keys.independentWindowControl) }
        set { defaults.set(newValue, forKey: Keys.independentWindowControl) }
    }
    var enableOriginalPreview: Bool {
        get { defaults.bool(forKey: Keys.originalPreview) }
        set { defaults.set(newValue, forKey: Keys.originalPreview) }
    }
    var enableFocusPreview: Bool {
        get { defaults.bool(forKey: Keys.focusPreview) }
        set { defaults.set(newValue, forKey: Keys.focusPreview) }
    }
    var previewStaysVisible: Bool {
        get { defaults.bool(forKey: Keys.previewStaysVisible) }
        set { defaults.set(newValue, forKey: Keys.previewStaysVisible) }
    }
    var shakeToFocusEnabled: Bool {
        get { defaults.bool(forKey: Keys.shakeToFocus) }
        set { defaults.set(newValue, forKey: Keys.shakeToFocus) }
    }
    var menuBarIconVisible: Bool {
        get { defaults.bool(forKey: Keys.menuBarIconVisible) }
        set {
            defaults.set(newValue, forKey: Keys.menuBarIconVisible)
            NotificationCenter.default.post(name: Self.menuBarIconChangedNotification, object: nil)
        }
    }
    var logEnabled: Bool {
        get { defaults.bool(forKey: Keys.logEnabled) }
        set { defaults.set(newValue, forKey: Keys.logEnabled) }
    }

    // MARK: - 开机启动

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 首次运行自动开启开机自启（只自动一次，之后尊重用户设置）
    var launchAtLoginAutoTried: Bool {
        get { defaults.bool(forKey: "launchAtLoginAutoTried") }
        set { defaults.set(newValue, forKey: "launchAtLoginAutoTried") }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            DebugLogger.shared.log("开机启动设置失败: \(error.localizedDescription)")
        }
    }
}
