//
//  main.swift
//  卸载 DockZoom（配套卸载器）
//
//  确认后：退出 DockZoom → 把 DockZoom.app / DockZoom 开关.app 移到废纸篓
//  → 清理日志与偏好设置。
//

import AppKit

final class UninstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "卸载 DockZoom？"
        alert.informativeText = """
        将执行以下操作：
        1. 退出正在运行的 DockZoom
        2. 把「DockZoom.app」和「DockZoom 开关.app」移到废纸篓
        3. 删除日志（~/Library/Logs/DockZoom）与偏好设置

        （清空废纸篓即彻底删除；本卸载器可自行拖入废纸篓）
        """
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            performUninstall()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func performUninstall() {
        let fm = FileManager.default

        // 1. 通知并退出 DockZoom
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.dockzoom.quit"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == "com.dockzoom.app" {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 1.0)

        // 2. 移到废纸篓
        for path in ["/Applications/DockZoom.app", "/Applications/DockZoom 开关.app"] {
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: path) {
                NSWorkspace.shared.recycle([url], completionHandler: nil)
            }
        }

        // 3. 删除日志目录
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let logs = lib.appendingPathComponent("Logs/DockZoom")
            try? fm.removeItem(at: logs)
        }

        // 4. 删除偏好设置
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "com.dockzoom.app"]
        try? defaults.run()
        defaults.waitUntilExit()

        // 5. 完成提示
        let done = NSAlert()
        done.messageText = "卸载完成"
        done.informativeText = "DockZoom 及其开关已移到废纸篓，日志和偏好设置已清理。"
        done.addButton(withTitle: "好")
        done.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = UninstallerAppDelegate()
app.delegate = delegate
app.run()
