//
//  main.swift
//  卸载 DockZoom（配套卸载器）
//
//  确认后：退出 DockZoom → 把 DockZoom.app / DockZoom 开关.app 移到废纸篓
//  → 清理日志与偏好设置。
//

import AppKit

final class UninstallerAppDelegate: NSObject, NSApplicationDelegate {
    private var uninstallPreparedObserver: NSObjectProtocol?

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
        // 1. 让主应用先注销 SMAppService 登录项再退出。
        uninstallPreparedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.dockzoom.uninstallPrepared"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let success = note.userInfo?["success"] as? Bool ?? false
            self?.continueUninstall(loginItemRemoved: success)
        }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.dockzoom.prepareUninstall"),
            object: nil, userInfo: nil, deliverImmediately: true
        )

        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.dockzoom.app"
        }
        if !running {
            launchMainAppForCleanup()
        }

        // 旧版主程序、启动失败或通知丢失时仍允许卸载，但会如实提示登录项可能残留。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.continueUninstall(loginItemRemoved: false)
        }
    }

    private func launchMainAppForCleanup() {
        let url = URL(fileURLWithPath: "/Applications/DockZoom.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--uninstall-cleanup"]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private var hasContinued = false

    private func continueUninstall(loginItemRemoved: Bool) {
        guard !hasContinued else { return }
        hasContinued = true
        if let observer = uninstallPreparedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            uninstallPreparedObserver = nil
        }

        let fm = FileManager.default

        // 2. 移到废纸篓
        let apps = ["/Applications/DockZoom.app", "/Applications/DockZoom 开关.app"]
            .filter { fm.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !apps.isEmpty else {
            cleanupAndFinish(loginItemRemoved: loginItemRemoved, recycleError: nil)
            return
        }

        NSWorkspace.shared.recycle(apps) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.cleanupAndFinish(loginItemRemoved: loginItemRemoved, recycleError: error)
            }
        }
    }

    private func cleanupAndFinish(loginItemRemoved: Bool, recycleError: Error?) {
        let fm = FileManager.default

        // 3. 删除日志目录
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let logs = lib.appendingPathComponent("Logs/DockZoom")
            try? fm.removeItem(at: logs)
        }

        // 4. 删除偏好设置
        for domain in ["com.dockzoom.app", "DockZoom"] {
            let defaults = Process()
            defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            defaults.arguments = ["delete", domain]
            do {
                try defaults.run()
                defaults.waitUntilExit()
            } catch {
                // 域不存在或命令无法启动时继续完成其余卸载步骤。
            }
        }

        // 5. 完成提示
        let done = NSAlert()
        if let recycleError {
            done.messageText = "卸载未完全完成"
            done.informativeText = "应用未能全部移到废纸篓：\(recycleError.localizedDescription)"
        } else if !loginItemRemoved {
            done.messageText = "应用已卸载"
            done.informativeText = "应用、日志和偏好设置已清理；登录项未能确认注销，请在系统设置中检查一次。"
        } else {
            done.messageText = "卸载完成"
            done.informativeText = "DockZoom 及其开关已移到废纸篓，登录项、日志和偏好设置已清理。"
        }
        done.addButton(withTitle: "好")
        done.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = UninstallerAppDelegate()
app.delegate = delegate
app.run()
