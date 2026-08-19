//
//  WindowStateTracker.swift
//  DockZoom
//
//  应用窗口状态快照跟踪器：
//  后台持续维护每个应用的 {是否前台, 是否隐藏, CG可见窗口数, AX最小化窗口数}，
//  让点击事件回调能以 O(1) 完成「接管/放行」决策——
//  决策不再依赖耗时枚举，也就不用"超时放行"，杜绝系统双重执行。
//

import Cocoa
import ApplicationServices

final class WindowStateTracker {
    static let shared = WindowStateTracker()

    struct Snapshot {
        var isActive: Bool
        var isHidden: Bool
        var visibleCount: Int      // CG 可见窗口数（layer 0，最小化窗口不计入）
        var minimizedCount: Int    // AX 已最小化窗口数
        var updatedAt: TimeInterval
    }

    enum QuickAction {
        case minimize        // 前台且有可见窗口 → 最小化
        case restore         // 无可见窗口但有最小化窗口 → 恢复
        case unhideActivate  // 已隐藏 → 恢复显示
        case activate        // 后台但有可见窗口 → 激活
        case none            // 无窗口可操作 → 放行交系统默认（Reopen 等）
    }

    private var snapshots: [pid_t: Snapshot] = [:]
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.dockzoom.state", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // 前台应用切换时立即刷新该应用
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.refreshNow(for: app)
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    // MARK: - 查询

    /// O(1) 意图决策（基于快照，无任何 AX/CG 调用）
    func quickAction(for app: NSRunningApplication) -> QuickAction {
        let s = snapshot(forPID: app.processIdentifier)
        if s.isHidden { return .unhideActivate }
        if s.visibleCount == 0 && s.minimizedCount > 0 { return .restore }
        if s.isActive && s.visibleCount > 0 { return .minimize }
        if !s.isActive && s.visibleCount > 0 { return .activate }
        return .none
    }

    /// CG 可见窗口数（供 AX 枚举失败时的兜底判断）
    func cgVisibleCount(for pid: pid_t) -> Int {
        snapshot(forPID: pid).visibleCount
    }

    private func snapshot(forPID pid: pid_t) -> Snapshot {
        lock.lock()
        if let s = snapshots[pid] {
            lock.unlock()
            return s
        }
        lock.unlock()
        // 冷启动兜底（快照尚未建立）：快速属性 + 保守假设"有可见窗口"
        let app = RunningAppsCache.shared.apps().first { $0.processIdentifier == pid }
        return Snapshot(
            isActive: app?.isActive ?? false,
            isHidden: app?.isHidden ?? false,
            visibleCount: 1,
            minimizedCount: 0,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - 刷新

    /// 全量刷新（1s 周期）：CG 列表只取一次，按 pid 计数
    func refresh() {
        var cgCounts: [pid_t: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for e in list {
                guard let pid = e[kCGWindowOwnerPID as String] as? Int32,
                      (e[kCGWindowLayer as String] as? Int ?? 1) == 0 else { continue }
                cgCounts[pid_t(pid), default: 0] += 1
            }
        }
        let service = WindowThumbnailService.shared
        for app in RunningAppsCache.shared.apps() where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let axMin = service.minimizedWindows(service.windows(for: app)).count
            lock.lock()
            snapshots[pid] = Snapshot(
                isActive: app.isActive,
                isHidden: app.isHidden,
                visibleCount: cgCounts[pid] ?? 0,
                minimizedCount: axMin,
                updatedAt: Date().timeIntervalSince1970
            )
            lock.unlock()
        }
    }

    /// 单个应用立即刷新（窗口动作完成后调用，保证下一次点击决策准确）
    func refreshNow(for app: NSRunningApplication) {
        queue.async { [weak self] in
            guard let self else { return }
            let pid = app.processIdentifier
            let service = WindowThumbnailService.shared
            let axMin = service.minimizedWindows(service.windows(for: app)).count
            let cgVisible = Self.countCGVisible(pid: pid)
            self.lock.lock()
            self.snapshots[pid] = Snapshot(
                isActive: app.isActive,
                isHidden: app.isHidden,
                visibleCount: cgVisible,
                minimizedCount: axMin,
                updatedAt: Date().timeIntervalSince1970
            )
            self.lock.unlock()
        }
    }

    static func countCGVisible(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int ?? 1) == 0
        }.count
    }
}
