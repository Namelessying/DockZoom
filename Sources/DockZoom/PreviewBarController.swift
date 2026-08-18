//
//  PreviewBarController.swift
//  DockZoom
//
//  悬停预览条：无边框浮窗（popUpMenu 层级）+ SwiftUI 缩略图卡片。
//  卡片点击 → 最小化/恢复该窗口；鼠标离开图标与预览条 0.35s 后自动收起。
//

import Cocoa
import SwiftUI

struct PreviewItem: Identifiable {
    let id: UInt32                    // CGWindowID
    let title: String
    let isMinimized: Bool
    var image: NSImage?
}

final class PreviewBarModel: ObservableObject {
    @Published var items: [PreviewItem] = []
    @Published var isMouseInside = false
    @Published var needsPermission = false
}

final class PreviewBarController {
    static let shared = PreviewBarController()

    let model = PreviewBarModel()
    private var window: NSPanel?
    private var currentAppPID: pid_t?
    private var currentIconRect: CGRect = .zero
    private var dismissWork: DispatchWorkItem?
    private var loadGeneration = 0

    // 悬停预取状态
    private var pendingPID: pid_t = -1
    private var pendingItems: [PreviewItem] = []

    private let cardWidth: CGFloat = 136
    private let barHeight: CGFloat = 166

    private init() {
        // 注意：必须是 NSPanel（NSWindow 不支持 nonactivatingPanel 样式）
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.level = .popUpMenu
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovable = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient]
        w.contentView = NSHostingView(rootView: PreviewBarView(model: model))
        window = w
    }

    // MARK: - 显示 / 隐藏

    /// 悬停预取：在 0.5s 悬停延迟期间后台枚举好窗口，到期瞬间出条
    func prefetch(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        if pendingPID == pid && !pendingItems.isEmpty { return }
        pendingPID = pid
        pendingItems = []
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let items = self.buildItems(for: app)
            if self.pendingPID == pid {
                self.pendingItems = items
            }
        }
    }

    private func buildItems(for app: NSRunningApplication) -> [PreviewItem] {
        WindowThumbnailService.shared.windows(for: app)
            .filter { !$0.isFloating }
            .sorted { a, b in
                if a.isMinimized != b.isMinimized { return !a.isMinimized }
                return a.title < b.title
            }
            .map { PreviewItem(id: $0.windowId, title: $0.title, isMinimized: $0.isMinimized, image: nil) }
    }

    func show(for app: NSRunningApplication, iconRect: CGRect, mouse: CGPoint) {
        cancelDismiss()
        if currentAppPID == app.processIdentifier {
            return   // 同应用：保持显示
        }
        currentAppPID = app.processIdentifier
        currentIconRect = iconRect

        // 预取命中 → 立即显示（灰色卡片，缩略图随后逐张填充）
        if pendingPID == app.processIdentifier, !pendingItems.isEmpty {
            let items = pendingItems
            pendingPID = -1
            pendingItems = []
            present(items: items, app: app)
            return
        }

        // 未命中：后台枚举（AX 调用可能阻塞，不能在事件回调主线程做）
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let items = self.buildItems(for: app)
            DispatchQueue.main.async {
                self.present(items: items, app: app)
            }
        }
    }

    /// 主线程显示预览条
    private func present(items: [PreviewItem], app: NSRunningApplication) {
        // 悬浮到其它图标可能已经切换/收起
        guard currentAppPID == app.processIdentifier, !items.isEmpty else {
            if items.isEmpty { DebugLogger.shared.log("预览条：应用无窗口，跳过显示") }
            return
        }
        model.items = items
        model.needsPermission = !ScreenCaptureManager.shared.hasPermission()
        // 不再自动弹屏幕录制授权框（打扰用户）；提示卡片上有按钮可手动授权
        positionWindow(itemCount: items.count + (model.needsPermission ? 1 : 0))
        window?.orderFrontRegardless()
        loadThumbnails(items: items)
        DebugLogger.shared.log("预览条显示: \(app.localizedName ?? "?") \(items.count) 个窗口 权限=\(!model.needsPermission)")
    }

    func hide() {
        let wasShown = currentAppPID != nil
        currentAppPID = nil
        pendingPID = -1
        pendingItems = []
        loadGeneration += 1
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.model.items = []
        }
        if wasShown {
            DebugLogger.shared.log("预览条收起")
        }
    }

    func mouseMovedOutside(point: CGPoint) {
        guard currentAppPID != nil, let window, window.isVisible else { return }
        // 命中检测：预览条内 → 取消收起；图标内 → 保持；两者之外 → 延时收起
        let akPoint = ScreenLocator.appKitPoint(fromCGGlobal: point)
        if window.frame.contains(akPoint) {
            cancelDismiss()
            return
        }
        let iconAkRect = self.iconAkRect()
        if iconAkRect.insetBy(dx: -6, dy: -6).contains(akPoint) {
            cancelDismiss()
            return
        }
        // 预览保持显示：鼠标仍在 Dock 区域内不收起
        if SettingsManager.shared.previewStaysVisible
            && DockEventMonitor.shared.isInDockRegion(point) {
            cancelDismiss()
            return
        }
        scheduleDismiss()
    }

    func mouseInsideChanged(_ inside: Bool) {
        model.isMouseInside = inside
        if inside {
            cancelDismiss()
        } else {
            scheduleDismiss()
        }
    }

    func cardClicked(_ windowId: UInt32) {
        guard let pid = currentAppPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        WindowManager.shared.toggleWindow(windowId: CGWindowID(windowId), app: app)
        // 刷新卡片状态
        let windows = WindowThumbnailService.shared.windows(for: app)
        DispatchQueue.main.async {
            self.model.items = windows
                .filter { !$0.isFloating }
                .sorted { a, b in
                    if a.isMinimized != b.isMinimized { return !a.isMinimized }
                    return a.title < b.title
                }
                .map { PreviewItem(id: $0.windowId, title: $0.title, isMinimized: $0.isMinimized, image: nil) }
            self.loadThumbnails(items: self.model.items)
        }
    }

    // MARK: - 私有

    private func scheduleDismiss() {
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.dismissWork = nil
            self?.hide()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func iconAkRect() -> CGRect {
        // Dock 图标 rect 是 CG 全局坐标（左上原点）→ AppKit 全局坐标（左下原点）
        let bottomLeft = ScreenLocator.appKitPoint(
            fromCGGlobal: CGPoint(x: currentIconRect.minX, y: currentIconRect.maxY)
        )
        return CGRect(
            x: currentIconRect.origin.x,
            y: bottomLeft.y,
            width: currentIconRect.width,
            height: currentIconRect.height
        )
    }

    private func positionWindow(itemCount: Int) {
        guard let window else { return }
        let iconRect = iconAkRect()
        let count = max(itemCount, 1)
        let width = min(CGFloat(count) * cardWidth + 24, 800)
        let height = barHeight

        // 按 Dock 方向定位预览条（底部=上方居中；左右=侧面垂直居中）
        let screen = window.screen ?? NSScreen.main
        let dockPos = DockPositionManager.shared.position(for: screen)
        var frame: NSRect
        switch dockPos {
        case .bottom:
            frame = NSRect(x: iconRect.midX - width / 2, y: iconRect.maxY + 8,
                           width: width, height: height)
        case .left:
            frame = NSRect(x: iconRect.maxX + 8, y: iconRect.midY - height / 2,
                           width: width, height: height)
        case .right:
            frame = NSRect(x: iconRect.minX - width - 8, y: iconRect.midY - height / 2,
                           width: width, height: height)
        }
        // 防出屏
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width - 8 }
            if frame.minX < visible.minX { frame.origin.x = visible.minX + 8 }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height - 8 }
            if frame.minY < visible.minY { frame.origin.y = visible.minY + 8 }
        }
        window.setFrame(frame, display: true)
    }

    private func loadThumbnails(items: [PreviewItem]) {
        guard ScreenCaptureManager.shared.hasPermission() else { return }
        let generation = loadGeneration
        // 每张卡片并行加载：灰色占位先显示，缩略图好了逐张填充（先到先显示）
        for (index, item) in items.enumerated() {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                let image = ScreenCaptureManager.shared.captureWindow(windowId: CGWindowID(item.id))
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration, index < self.model.items.count else { return }
                    self.model.items[index].image = image
                }
            }
        }
    }
}

// MARK: - SwiftUI 视图

struct PreviewBarView: View {
    @ObservedObject var model: PreviewBarModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.needsPermission {
                    PermissionHintCard()
                        .onTapGesture {
                            ScreenCaptureManager.shared.openPermissionSettings()
                        }
                }
                ForEach(model.items) { item in
                    PreviewCard(item: item)
                        .onTapGesture {
                            PreviewBarController.shared.cardClicked(item.id)
                        }
                }
            }
            .padding(10)
        }
        .frame(height: 166)
        .background(
            VisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .onHover { inside in
            PreviewBarController.shared.mouseInsideChanged(inside)
        }
    }
}

/// 屏幕录制权限提示卡片
struct PermissionHintCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.yellow)
            Text("需要屏幕录制权限\n才能显示窗口预览")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
            Text("点击去授权")
                .font(.system(size: 11).bold())
                .foregroundColor(.accentColor)
        }
        .frame(width: 128, height: 128)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
        )
    }
}

struct PreviewCard: View {
    let item: PreviewItem

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.25))
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 128, height: 96)

            Text(item.title.isEmpty ? "窗口" : item.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 128)

            // 状态条：蓝 = 显示中，灰 = 已最小化（Windows 任务栏风格）
            Rectangle()
                .fill(item.isMinimized ? Color.gray : Color.accentColor)
                .frame(width: 128, height: 2)
        }
    }
}

/// 液态玻璃背景
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
