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

enum DockDecision {
    static func quickAction(for snapshot: DockWindowSnapshot?) -> DockQuickAction {
        guard let snapshot else { return .none }
        if snapshot.isHidden { return .unhideActivate }
        if snapshot.visibleCount == 0 && snapshot.minimizedCount > 0 { return .restore }
        if snapshot.isActive && snapshot.visibleCount > 0 { return .minimize }
        if !snapshot.isActive && snapshot.visibleCount > 0 { return .activate }
        return .none
    }

    static func isLikelyVisibleWindow(layer: Int, alpha: Double, width: Double, height: Double) -> Bool {
        layer == 0 && alpha > 0.01 && width > 1 && height > 1
    }
}
