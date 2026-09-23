//
//  SteamHandler.swift
//  DockZoom
//
//  Steam 的 Dock 图标属于 com.valvesoftware.steam，但真正拥有窗口和前台状态的
//  是 com.valvesoftware.steam.helper。将两者视作同一个应用族，避免 Dock 点击漏接。
//

import Cocoa

enum SteamHandler {
    static let mainBundleID = "com.valvesoftware.steam"
    static let helperBundleID = "com.valvesoftware.steam.helper"

    static func handles(_ bundleID: String?) -> Bool {
        bundleID == mainBundleID || bundleID == helperBundleID
    }

    static func settingsBundleID(for bundleID: String?) -> String? {
        handles(bundleID) ? mainBundleID : bundleID
    }

    static func decide(app: NSRunningApplication, action: DockQuickAction) {
        switch action {
        case .minimize:
            let windows = WindowThumbnailService.shared.windows(for: app)
            let visible = WindowThumbnailService.shared.visibleStandardWindows(windows)
            if !visible.isEmpty {
                WindowManager.shared.minimize(windows: visible, app: app)
                return
            }
            WindowManager.shared.fallbackMinimize(app: app)

        case .restore:
            WindowManager.shared.restoreAll(
                windows: WindowThumbnailService.shared.windows(for: app),
                app: app
            )

        case .unhideActivate:
            let windows = WindowThumbnailService.shared.windows(for: app)
            if !WindowThumbnailService.shared.minimizedWindows(windows).isEmpty {
                WindowManager.shared.restoreAll(windows: windows, app: app)
                return
            }
            activate(app)

        case .activate:
            activate(app)

        case .none:
            break
        }
    }

    private static func activate(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        if app.activate(options: [.activateAllWindows]) {
            WindowStateTracker.shared.refreshNow(for: app)
            return
        }

        // Helper 偶尔拒绝直接 activate；改由主 .app 交给 LaunchServices 唤起。
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainBundleID) else {
            DebugLogger.shared.log("Steam 激活失败：找不到主应用")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                DebugLogger.shared.log("Steam 激活失败：\(error.localizedDescription)")
            }
        }
    }
}
