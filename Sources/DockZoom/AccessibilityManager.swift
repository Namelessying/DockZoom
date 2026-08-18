//
//  AccessibilityManager.swift
//  DockZoom
//

import AppKit
import ApplicationServices

final class AccessibilityManager {
    static let shared = AccessibilityManager()
    private init() {}

    /// 是否已授予辅助功能权限
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 主动请求权限（弹系统授权框）
    @discardableResult
    func promptIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 → 辅助功能」面板
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 权限"真可用"判定：不仅信任，还能实际读到 Dock 的 AX 树
    /// （能识别"已信任但 AX 调用仍失败"的边界情况）
    func isActuallyWorking() -> Bool {
        guard isTrusted else { return false }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        let dockRef = AXUIElementCreateApplication(dock.processIdentifier)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(dockRef, kAXChildrenAttribute as CFString, &value)
        return result == .success
    }
}
