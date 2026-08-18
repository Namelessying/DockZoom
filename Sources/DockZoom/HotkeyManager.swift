//
//  HotkeyManager.swift
//  DockZoom
//
//  全局快捷键：为任意应用绑定快捷键，按一次唤出、再按一次隐藏（跳过黑名单）。
//  使用 Carbon RegisterEventHotKey；绑定变更时整体重注册。
//  暂停键另有独立的事件监听备用通道（不依赖 Carbon，合成/真实按键均生效）。
//

import Cocoa
import Carbon.HIToolbox

func keyWatchTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = HotkeyManager.shared.handleKeyWatch(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var handlerRef: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var idToBundle: [UInt32: String] = [:]
    private var started = false

    // 暂停键备用通道：session 事件监听（不依赖 Carbon）
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var lastPauseFire: TimeInterval = 0

    private static let signature: OSType = 0x444B_5A4D   // 'DKZM'

    func start() {
        guard !started else { return }
        started = true
        installHandler()
        reapply()
        startKeyWatcher()
    }

    /// 按当前设置重新注册全部快捷键
    func reapply() {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        idToBundle.removeAll()

        var index: UInt32 = 1
        for (bundleID, shortcut) in SettingsManager.shared.hotkeyBindings {
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: index)
            var hotKeyRef: EventHotKeyRef?
            // ⚠️ CGEventFlags 与 Carbon 修饰键掩码是两套位值，必须转换
            //（否则 ⌘/⌥ 组合永远无法触发，只有 ⌃/⇧ 恰好同值能用）
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                Self.carbonModifiers(from: shortcut.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let ref = hotKeyRef {
                refs.append(ref)
                idToBundle[index] = bundleID
            } else {
                DebugLogger.shared.log("快捷键注册失败: \(bundleID) (\(status))")
            }
            index += 1
        }
        DebugLogger.shared.log("快捷键已重注册：\(idToBundle.count) 个")
    }

    /// CGEventFlags → Carbon 修饰键掩码（兼容新旧位值，不同 SDK 位值不同）
    static func carbonModifiers(from cg: UInt32) -> UInt32 {
        let flags = CGEventFlags(rawValue: UInt64(cg))
        let raw = UInt64(cg)
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if flags.contains(.maskControl) || raw & (0x1000 | 0x04 | 0x20) != 0 { m |= UInt32(controlKey) }
        if flags.contains(.maskShift) || raw & (0x200 | 0x02) != 0 { m |= UInt32(shiftKey) }
        return m
    }

    // MARK: - 暂停键备用监听（不依赖 Carbon 热键投递）

    private func startKeyWatcher() {
        guard keyTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyWatchTapCallback,
            userInfo: nil
        ) else {
            DebugLogger.shared.log("暂停键备用监听创建失败（无辅助功能权限，依赖 Carbon 通道）")
            return
        }
        keyTap = tap
        keyTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = keyTapSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 事件监听路径：匹配用户设置的暂停键（默认 ⌃⌥⇧⌘F13）
    func handleKeyWatch(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        guard let shortcut = SettingsManager.shared.hotkey(for: SettingsManager.pauseBundleID) else {
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let normGot = Self.normalizedMods(event.flags)
        let normWant = Self.normalizedMods(CGEventFlags(rawValue: UInt64(shortcut.modifiers)))
        guard code == Int64(shortcut.keyCode) else { return false }
        guard normGot == normWant else {
            return false
        }
        // 与 Carbon 通道去重
        let now = Date().timeIntervalSince1970
        guard now - lastPauseFire > 0.5 else { return false }
        lastPauseFire = now
        DebugLogger.shared.log("暂停键触发（事件监听路径）")
        NotificationCenter.default.post(name: SettingsManager.togglePauseNotification, object: nil)
        return true
    }

    /// 修饰键归一化：不同 SDK / WindowServer 重编码都会改变位值，
    /// 把所有候选位（新值/旧值/兼容位）映射到 {0=cmd, 1=alt, 2=ctrl, 3=shift} 集合再比较
    static func normalizedMods(_ flags: CGEventFlags) -> Set<Int> {
        var s = Set<Int>()
        let raw = flags.rawValue
        if flags.contains(.maskCommand) || raw & 0x10 != 0 { s.insert(0) }
        if flags.contains(.maskAlternate) || raw & 0x08 != 0 { s.insert(1) }
        if flags.contains(.maskControl) || raw & (0x04 | 0x20 | 0x1000) != 0 { s.insert(2) }
        if flags.contains(.maskShift) || raw & (0x02 | 0x200) != 0 { s.insert(3) }
        return s
    }

    // MARK: - Carbon 热键

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, let bundleID = manager.idToBundle[hotKeyID.id] else {
                    DebugLogger.shared.log("热键触发但映射失败: id=\(hotKeyID.id) err=\(err)")
                    return noErr
                }
                DebugLogger.shared.log("热键触发: id=\(hotKeyID.id) bundle=\(bundleID)")
                if bundleID == SettingsManager.bossKeyBundleID {
                    WindowManager.shared.minimizeAllWindows()
                } else if bundleID == SettingsManager.pauseBundleID {
                    manager.lastPauseFire = Date().timeIntervalSince1970
                    NotificationCenter.default.post(name: SettingsManager.togglePauseNotification, object: nil)
                } else {
                    WindowManager.shared.toggleViaHotkey(bundleID: bundleID)
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        if status != noErr {
            DebugLogger.shared.log("Carbon 热键事件处理器安装失败: \(status)")
        }
    }
}
