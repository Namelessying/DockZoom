//
//  main.swift
//  DockZoom 开关（配套小应用）
//
//  通过分布式通知控制 DockZoom：暂停/恢复、退出、打开。
//

import AppKit

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // 关窗即退出开关 App
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockZoom 开关"
        window.center()

        let content = NSView(frame: window.contentLayoutRect)

        let title = NSTextField(labelWithString: "DockZoom 控制台")
        title.font = .boldSystemFont(ofSize: 18)

        let toggle = NSButton(title: "暂停 / 恢复使用 DockZoom", target: self, action: #selector(togglePause))
        toggle.bezelStyle = .rounded
        toggle.controlSize = .large

        let openBtn = NSButton(title: "打开 DockZoom（若未运行）", target: self, action: #selector(openDockZoom))
        let quitBtn = NSButton(title: "退出 DockZoom", target: self, action: #selector(quitDockZoom))
        let uninstallBtn = NSButton(title: "卸载 DockZoom…", target: self, action: #selector(openUninstaller))

        let hint = NSTextField(wrappingLabelWithString:
            "提示：暂停后点击 Dock 图标恢复系统默认行为；\n按 ⌃⌥⇧⌘F13 可随时暂停/恢复。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, toggle, openBtn, quitBtn, uninstallBtn, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
        ])
        window.contentView = content
    }

    private func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @objc private func togglePause() {
        post("com.dockzoom.togglePause")
    }

    @objc private func quitDockZoom() {
        post("com.dockzoom.quit")
    }

    @objc private func openDockZoom() {
        let url = URL(fileURLWithPath: "/Applications/DockZoom.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "未找到 DockZoom.app"
            alert.informativeText = "请确认 DockZoom.app 在「应用程序」文件夹中。"
            alert.runModal()
            return
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.dockzoom.app" }) {
            return   // 已在运行
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openUninstaller() {
        let url = URL(fileURLWithPath: "/Applications/卸载 DockZoom.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "未找到卸载器"
            alert.informativeText = "请从「DockZoom 全套.dmg」把「卸载 DockZoom.app」拖入「应用程序」。"
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = LauncherAppDelegate()
app.delegate = delegate
app.run()
