//
//  ShakeMonitor.swift
//  DockZoom
//
//  摇窗聚焦：按住窗口快速横向摇晃 → 最小化其它窗口；再次摇晃 → 恢复。
//  检测阈值（来自 DockMinimize 经验）：≥3 次方向变化、每段位移 ≥34px、1.05s 内、冷却 1s。
//

import Cocoa
import ApplicationServices

func shakeEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    ShakeMonitor.shared.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class ShakeMonitor {
    static let shared = ShakeMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 手势状态
    private var tracking = false
    private var lastX: CGFloat = 0
    private var lastDirection: Int = 0
    private var directionChanges = 0
    private var startTime: TimeInterval = 0
    private var lastShakeTime: TimeInterval = 0
    private var shakenWindow: (pid: pid_t, windowId: CGWindowID)?

    private let minSegment: CGFloat = 34
    private let maxDuration: TimeInterval = 1.05
    private let cooldown: TimeInterval = 1.0

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,    // 只监听，不拦截
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: shakeEventTapCallback,
            userInfo: nil
        ) else {
            DebugLogger.shared.log("摇窗监听 EventTap 创建失败")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func handleEvent(type: CGEventType, event: CGEvent) {
        guard SettingsManager.shared.shakeToFocusEnabled else { return }

        switch type {
        case .leftMouseDown:
            beginTracking(event)
        case .leftMouseDragged:
            guard tracking else { return }
            trackDrag(event)
        case .leftMouseUp:
            tracking = false
            lastDirection = 0
            directionChanges = 0
        default:
            break
        }
    }

    // MARK: - 手势检测

    private func beginTracking(_ event: CGEvent) {
        let now = Date().timeIntervalSince1970
        guard now - lastShakeTime > cooldown else { return }
        guard let window = windowAt(event.location) else {
            tracking = false
            return
        }
        tracking = true
        lastX = event.location.x
        lastDirection = 0
        directionChanges = 0
        startTime = now
        shakenWindow = window
    }

    private func trackDrag(_ event: CGEvent) {
        let x = event.location.x
        let dx = x - lastX
        guard abs(dx) >= minSegment else { return }
        let direction = dx > 0 ? 1 : -1
        if lastDirection != 0 && direction != lastDirection {
            directionChanges += 1
            if directionChanges >= 3 {
                let elapsed = Date().timeIntervalSince1970 - startTime
                if elapsed <= maxDuration {
                    trigger()
                    tracking = false
                    lastDirection = 0
                    directionChanges = 0
                }
                return
            }
        }
        lastDirection = direction
        lastX = x
    }

    private func trigger() {
        lastShakeTime = Date().timeIntervalSince1970
        guard let shakenWindow else { return }
        DebugLogger.shared.log("摇窗聚焦触发 (pid=\(shakenWindow.pid))")
        WindowManager.shared.handleShake(shakenWindow: shakenWindow)
    }

    /// 鼠标下的窗口（AX 实时命中）
    private func windowAt(_ cgPoint: CGPoint) -> (pid: pid_t, windowId: CGWindowID)? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &element)
        guard err == .success, let el = element else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &wid) == .success, wid != 0 else { return nil }
        // 定位所属进程
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
            if let num = entry[kCGWindowNumber as String] as? Int, CGWindowID(num) == wid,
               let pid = entry[kCGWindowOwnerPID as String] as? Int32 {
                return (pid_t(pid), wid)
            }
        }
        return nil
    }
}
