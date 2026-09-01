//
//  DockDecision.swift
//  DockZoom
//
//  不依赖系统 API 的点击决策模型，方便对关键行为做单元测试。
//

import Foundation

struct DockWindowSnapshot: Equatable {
    var isActive: Bool
    var isHidden: Bool
    var visibleCount: Int
    var minimizedCount: Int
}

enum DockQuickAction: Equatable {
    case minimize
    case restore
    case unhideActivate
    case activate
    case none
}

struct DockExecutionSnapshot: Equatable {
    var isActive: Bool
    var isHidden: Bool
    var axVisibleCount: Int
    var axMinimizedCount: Int
    var cgVisibleCount: Int
}

enum DockExecutionAction: Equatable {
    case minimize
    case restore
    case unhideActivate
    case hideFallback
    case activate
}

enum DockDecision {
    static func quickAction(for snapshot: DockWindowSnapshot?) -> DockQuickAction {
        guard let snapshot else { return .none }
        if snapshot.isHidden { return .unhideActivate }
        if snapshot.visibleCount == 0 && snapshot.minimizedCount > 0 { return .restore }
        if snapshot.isActive && snapshot.visibleCount > 0 { return .minimize }
        if !snapshot.isActive && snapshot.visibleCount > 0 { return .activate }
        return .none
    }

    /// Steam 的窗口由 Helper 承载且不稳定地暴露 AX 最小化状态。
    /// 只依据应用族的前台、隐藏和 CG 可见状态做确定性切换。
    static func steamQuickAction(for snapshot: DockWindowSnapshot?) -> DockQuickAction {
        guard let snapshot else { return .none }
        if snapshot.isHidden || snapshot.visibleCount == 0 { return .unhideActivate }
        return snapshot.isActive ? .minimize : .activate
    }

    static func isLikelyVisibleWindow(layer: Int, alpha: Double, width: Double, height: Double) -> Bool {
        layer == 0 && alpha > 0.01 && width > 1 && height > 1
    }

    static func executionAction(for snapshot: DockExecutionSnapshot) -> DockExecutionAction {
        if snapshot.isHidden { return .unhideActivate }
        if snapshot.isActive && snapshot.axVisibleCount > 0 { return .minimize }
        if snapshot.axVisibleCount == 0 && snapshot.axMinimizedCount > 0 { return .restore }
        if snapshot.isActive &&
            snapshot.axVisibleCount == 0 && snapshot.cgVisibleCount > 0 {
            return .hideFallback
        }
        return .activate
    }
}
