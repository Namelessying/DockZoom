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

    private var snapshots: [pid_t: Snapshot] = [:]
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.dockzoom.state", qos: .utility)
    private let urgentQueue = DispatchQueue(label: "com.dockzoom.state.urgent", qos: .userInteractive)
    private var started = false
    private var workspaceObservers: [NSObjectProtocol] = []
    /// 过期快照只能放行给系统，不能据此吞掉 Dock 点击。
    // AX 服务偶尔会因单个应用无响应而拖慢周期采样；允许跨过数个采样周期，
    // 避免某个坏应用导致所有 Dock 点击同时退化为系统默认行为。
    private let snapshotMaxAge: TimeInterval = 8.0

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter

        // 前台应用切换、应用启动/退出时立即失效缓存；周期采样仅作为兜底。
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            RunningAppsCache.shared.invalidate()
            self?.refreshNow(for: app)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] note in
            RunningAppsCache.shared.invalidate()
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.refreshNow(for: app)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] note in
            RunningAppsCache.shared.invalidate()
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeSnapshot(forPID: app.processIdentifier)
        })

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    // MARK: - 查询

    /// O(1) 意图决策（基于快照，无任何 AX/CG 调用）
    func quickAction(for app: NSRunningApplication) -> DockQuickAction {
        let snapshot = freshSnapshot(forPID: app.processIdentifier).map {
            DockWindowSnapshot(
                isActive: $0.isActive,
                isHidden: $0.isHidden,
                visibleCount: $0.visibleCount,
                minimizedCount: $0.minimizedCount
            )
        }
        return DockDecision.quickAction(for: snapshot)
    }

    /// CG 可见窗口数（供 AX 枚举失败时的兜底判断）
    func cgVisibleCount(for pid: pid_t) -> Int {
        freshSnapshot(forPID: pid)?.visibleCount ?? 0
    }

    private func freshSnapshot(forPID pid: pid_t) -> Snapshot? {
        guard pid > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let result = snapshots[pid].flatMap { now - $0.updatedAt <= snapshotMaxAge ? $0 : nil }
        lock.unlock()
        return result
    }

    // MARK: - 刷新

    /// 全量刷新（1s 周期）：CG 列表只取一次，按 pid 计数
    func refresh() {
        var cgCounts: [pid_t: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for e in list {
                guard let pid = e[kCGWindowOwnerPID as String] as? Int32,
                      Self.isLikelyVisibleWindow(e) else { continue }
                cgCounts[pid_t(pid), default: 0] += 1
            }
        }
        let service = WindowThumbnailService.shared
        let apps = RunningAppsCache.shared.apps().filter { $0.activationPolicy == .regular }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for app in apps {
            let pid = app.processIdentifier
            let sampledAt = Date().timeIntervalSince1970
            let isHidden = app.isHidden
            let visibleCount = cgCounts[pid] ?? 0
            // 有 CG 可见窗口或整个应用已隐藏时，QuickAction 不需要 AX 最小化数；
            // 只查询“无可见且未隐藏”的应用，避免每秒轰炸所有进程的 AX 服务。
            let axMin = (!isHidden && visibleCount == 0)
                ? service.minimizedWindows(service.windows(for: app)).count
                : 0
            store(Snapshot(
                isActive: app.isActive,
                isHidden: isHidden,
                visibleCount: visibleCount,
                minimizedCount: axMin,
                updatedAt: sampledAt
            ), forPID: pid)
        }
        lock.lock()
        snapshots = snapshots.filter { livePIDs.contains($0.key) }
        lock.unlock()
    }

    /// 单个应用立即刷新（窗口动作完成后调用，保证下一次点击决策准确）
    func refreshNow(for app: NSRunningApplication) {
        urgentQueue.async { [weak self] in
            guard let self else { return }
            let pid = app.processIdentifier
            guard pid > 0, !app.isTerminated else { return }
            let sampledAt = Date().timeIntervalSince1970
            let service = WindowThumbnailService.shared
            let axMin = service.minimizedWindows(service.windows(for: app)).count
            let cgVisible = Self.countCGVisible(pid: pid)
            self.store(Snapshot(
                isActive: app.isActive,
                isHidden: app.isHidden,
                visibleCount: cgVisible,
                minimizedCount: axMin,
                updatedAt: sampledAt
            ), forPID: pid)
        }
    }

    /// 最小化/恢复带有系统动画，立即采样会读到过渡态；动画结束后再刷新。
    func refreshAfterWindowTransition(for app: NSRunningApplication, delay: TimeInterval = 0.45) {
        urgentQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak app] in
            guard let self, let app else { return }
            let pid = app.processIdentifier
            guard pid > 0, !app.isTerminated else { return }
            let sampledAt = Date().timeIntervalSince1970
            let service = WindowThumbnailService.shared
            let axMin = service.minimizedWindows(service.windows(for: app)).count
            let cgVisible = Self.countCGVisible(pid: pid)
            self.store(Snapshot(
                isActive: app.isActive,
                isHidden: app.isHidden,
                visibleCount: cgVisible,
                minimizedCount: axMin,
                updatedAt: sampledAt
            ), forPID: pid)
        }
    }

    /// 较早开始的周期采样不得覆盖动作后的紧急采样。
    private func store(_ snapshot: Snapshot, forPID pid: pid_t) {
        lock.lock()
        if snapshots[pid]?.updatedAt ?? 0 <= snapshot.updatedAt {
            snapshots[pid] = snapshot
        }
        lock.unlock()
    }

    private func removeSnapshot(forPID pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        snapshots.removeValue(forKey: pid)
        lock.unlock()
    }

    private static func isLikelyVisibleWindow(_ entry: [String: Any]) -> Bool {
        let layer = entry[kCGWindowLayer as String] as? Int ?? 1
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
        let bounds = (entry[kCGWindowBounds as String] as? [String: Any]).flatMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        } ?? .zero
        return DockDecision.isLikelyVisibleWindow(
            layer: layer,
            alpha: alpha,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func countCGVisible(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && Self.isLikelyVisibleWindow($0)
        }.count
    }
}
