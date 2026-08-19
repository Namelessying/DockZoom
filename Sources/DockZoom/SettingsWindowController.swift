//
//  SettingsWindowController.swift
//  DockZoom
//  设置面板：SwiftUI 六标签页（通用 / 预览 / 黑名单 / 快捷键 / 权限 / 关于）
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockZoom 设置"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        // 支持窗口恢复解码（系统恢复设置窗口时不能崩溃）
        super.init(coder: coder)
    }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 根视图

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("通用", systemImage: "gearshape") }
            PreviewTab().tabItem { Label("预览", systemImage: "rectangle.3.group") }
            BlacklistTab().tabItem { Label("黑名单", systemImage: "nosign") }
            HotkeyTab().tabItem { Label("快捷键", systemImage: "command") }
            PermissionTab().tabItem { Label("权限", systemImage: "lock.shield") }
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding(8)
    }
}

// MARK: - 通用

struct GeneralTab: View {
    @State private var launchAtLogin = SettingsManager.shared.launchAtLoginEnabled
    @State private var menuBarIcon = SettingsManager.shared.menuBarIconVisible
    @State private var shakeToFocus = SettingsManager.shared.shakeToFocusEnabled
    @State private var logEnabled = SettingsManager.shared.logEnabled

    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _ in SettingsManager.shared.setLaunchAtLogin(launchAtLogin) }
            }
            Section("行为") {
                Toggle("显示菜单栏图标", isOn: $menuBarIcon)
                    .onChange(of: menuBarIcon) { _ in SettingsManager.shared.menuBarIconVisible = menuBarIcon }
                Toggle("摇窗聚焦（按住窗口摇晃最小化其它窗口）", isOn: $shakeToFocus)
                    .onChange(of: shakeToFocus) { _ in SettingsManager.shared.shakeToFocusEnabled = shakeToFocus }
                Toggle("写入调试日志", isOn: $logEnabled)
                    .onChange(of: logEnabled) { _ in
                        SettingsManager.shared.logEnabled = logEnabled
                        DebugLogger.shared.enabled = logEnabled
                    }
            }
            Section("维护") {
                Button("检查更新") { UpdateChecker.shared.check(manual: true) }
                Button("打开日志目录") { DebugLogger.shared.openLogDirectory() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 预览

struct PreviewTab: View {
    @State private var hover = SettingsManager.shared.hoverPreviewEnabled
    @State private var independent = SettingsManager.shared.enableIndependentWindowControl
    @State private var original = SettingsManager.shared.enableOriginalPreview
    @State private var focus = SettingsManager.shared.enableFocusPreview
    @State private var stays = SettingsManager.shared.previewStaysVisible

    var body: some View {
        Form {
            Section("悬停预览") {
                Toggle("悬停 Dock 图标显示窗口预览", isOn: $hover)
                    .onChange(of: hover) { _ in SettingsManager.shared.hoverPreviewEnabled = hover }
                Toggle("预览条保持显示（离开图标不立即收起）", isOn: $stays)
                    .onChange(of: stays) { _ in SettingsManager.shared.previewStaysVisible = stays }
                Toggle("子窗口独立控制（点击缩略图最小化/恢复单个窗口）", isOn: $independent)
                    .onChange(of: independent) { _ in SettingsManager.shared.enableIndependentWindowControl = independent }
            }
            Section("高级预览（计划功能）") {
                Toggle("原位预览", isOn: $original)
                    .onChange(of: original) { _ in SettingsManager.shared.enableOriginalPreview = original }
                Toggle("聚焦预览（预览时模糊桌面其余区域）", isOn: $focus)
                    .onChange(of: focus) { _ in SettingsManager.shared.enableFocusPreview = focus }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 黑名单

struct BlacklistTab: View {
    @State private var entries: [BlacklistEntry] = loadEntries()

    struct BlacklistEntry: Identifiable {
        let id: String          // bundleID
        let name: String
    }

    static func loadEntries() -> [BlacklistEntry] {
        SettingsManager.shared.blacklistedBundleIDs.map { id in
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
                .deletingPathExtension().lastPathComponent ?? id
            return BlacklistEntry(id: id, name: name)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("黑名单中的应用会被完全跳过：点击 Dock 图标时保持系统默认行为（适用于贴边隐藏、会拦截点击行为的特殊软件）。")
                .font(.callout)
                .foregroundColor(.secondary)
            List(entries) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Button("移除") {
                        SettingsManager.shared.removeBlacklist(entry.id)
                        entries = Self.loadEntries()
                    }
                }
            }
            HStack {
                Button("添加应用…") { addApp() }
                Spacer()
            }
        }
        .padding(8)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "加入黑名单"
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            SettingsManager.shared.addBlacklist(id)
            entries = Self.loadEntries()
        }
    }
}

// MARK: - 快捷键

final class AppHotkeyRow: Identifiable, ObservableObject {
    let id = UUID()
    let bundleID: String
    let name: String
    @Published var shortcut: KeyboardShortcut?
    @Published var recording = false

    init(bundleID: String, name: String, shortcut: KeyboardShortcut?) {
        self.bundleID = bundleID
        self.name = name
        self.shortcut = shortcut
    }
}

struct HotkeyTab: View {
    @State private var bossKey = SettingsManager.shared.hotkey(for: SettingsManager.bossKeyBundleID)
    @State private var recordingBoss = false
    @State private var pauseKey = SettingsManager.shared.hotkey(for: SettingsManager.pauseBundleID)
    @State private var recordingPause = false
    @State private var rows: [AppHotkeyRow] = loadAppRows()

    static func loadAppRows() -> [AppHotkeyRow] {
        var seen = Set<String>()
        var rows: [AppHotkeyRow] = []
        for app in RunningAppsCache.shared.apps() where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            rows.append(AppHotkeyRow(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                shortcut: SettingsManager.shared.hotkey(for: bundleID)
            ))
        }
        return rows.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                Section("一键最小化所有窗口（老板键）") {
                    HStack {
                        Text("老板键")
                        Spacer()
                        ShortcutRecorder(shortcut: $bossKey, recording: $recordingBoss) { newValue in
                            SettingsManager.shared.setHotkey(newValue, for: SettingsManager.bossKeyBundleID)
                            HotkeyManager.shared.reapply()
                        }
                    }
                }
                Section("暂停 / 恢复使用（默认 ⌃⌥⇧⌘F13，几乎不可能误触）") {
                    HStack {
                        Text("暂停键")
                        Spacer()
                        ShortcutRecorder(shortcut: $pauseKey, recording: $recordingPause) { newValue in
                            SettingsManager.shared.setHotkey(newValue, for: SettingsManager.pauseBundleID)
                            HotkeyManager.shared.reapply()
                        }
                    }
                }
            }
            .frame(height: 170)
            .formStyle(.grouped)

            Text("应用快捷键：按一次唤出，再按一次隐藏（当前运行的应用）")
                .font(.callout)
                .foregroundColor(.secondary)
            List(rows) { row in
                AppHotkeyRowView(row: row)
            }
            Button("刷新应用列表") {
                rows = Self.loadAppRows()
                HotkeyManager.shared.reapply()
            }
        }
        .padding(8)
    }
}

struct AppHotkeyRowView: View {
    @ObservedObject var row: AppHotkeyRow

    var body: some View {
        HStack {
            Text(row.name)
            Spacer()
            ShortcutRecorder(shortcut: $row.shortcut, recording: $row.recording) { newValue in
                SettingsManager.shared.setHotkey(newValue, for: row.bundleID)
                HotkeyManager.shared.reapply()
            }
        }
    }
}

/// 录制式快捷键控件
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?
    @Binding var recording: Bool
    var onRecord: (KeyboardShortcut?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let title: String
        if recording {
            title = "按下快捷键… (ESC 取消)"
        } else if let s = shortcut {
            title = s.displayString
        } else {
            title = "未设置"
        }
        button.title = title
    }

    final class Coordinator: NSObject {
        var parent: ShortcutRecorder
        private var monitor: Any?

        init(_ parent: ShortcutRecorder) { self.parent = parent }

        @objc func clicked(_ sender: NSButton) {
            if parent.recording {
                parent.recording = false
                stopMonitor()
            } else {
                parent.recording = true
                startMonitor()
            }
        }

        private func startMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {   // ESC：取消
                    self.parent.recording = false
                    self.stopMonitor()
                    return nil
                }
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                // 无修饰键时只允许功能键（F1-F20 的 Unicode 私有区段），防止误绑普通按键
                let chars = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
                let isFunctionKey = chars >= 0xF700 && chars <= 0xF8FF
                guard !mods.isEmpty || isFunctionKey else {
                    return event
                }
                let shortcut = KeyboardShortcut(
                    keyCode: event.keyCode,
                    modifiers: UInt32(mods.rawValue),
                    keyName: event.charactersIgnoringModifiers?.uppercased() ?? ""
                )
                self.parent.onRecord(shortcut)
                self.parent.recording = false
                self.stopMonitor()
                return nil
            }
        }

        private func stopMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}

// MARK: - 权限

struct PermissionTab: View {
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var axWorking = AccessibilityManager.shared.isActuallyWorking()
    @State private var screenCapture = CGPreflightScreenCaptureAccess()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("辅助功能（必需：监听 Dock 点击 + 控制窗口）") {
                Label(statusText, systemImage: axWorking ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(axWorking ? .green : .red)
                HStack {
                    Button("请求权限") { AccessibilityManager.shared.promptIfNeeded() }
                    Button("打开系统设置") { AccessibilityManager.shared.openSettings() }
                }
                Text("若列表里已勾选 DockZoom 但仍显示未授权（升级后常见）：在列表中选中 DockZoom 点「-」移除，再点「+」重新添加，或先取消勾选再重新勾选。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("屏幕录制（可选：悬停预览的窗口缩略图）") {
                Label(screenCapture ? "已授权" : "未授权", systemImage: screenCapture ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(screenCapture ? .green : .red)
                HStack {
                    Button("请求权限") { ScreenCaptureManager.shared.requestPermission() }
                    Button("打开系统设置") { ScreenCaptureManager.shared.openPermissionSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            axTrusted = AXIsProcessTrusted()
            axWorking = AccessibilityManager.shared.isActuallyWorking()
            screenCapture = CGPreflightScreenCaptureAccess()
        }
    }

    private var statusText: String {
        if axWorking { return "已授权且可用" }
        if axTrusted { return "已信任但 AX 调用失败" }
        return "未授权"
    }
}

// MARK: - 关于

struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? kDockZoomVersion
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("DockZoom").font(.title.bold())
            Text("版本 \(version)")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("点击 Dock 图标最小化/恢复窗口，保留苹果原生 genie 动画；适配微信、Finder 等特殊应用；支持悬停预览、摇窗聚焦、全局快捷键。")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("参考项目：oidd/DockMinimize (MIT)、Avi7ii/GetBackMyWindows (MIT)、JackTonyMa/DockMinimizer、DockDoor、alt-tab-macos")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
