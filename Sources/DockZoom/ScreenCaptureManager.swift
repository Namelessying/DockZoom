//
//  ScreenCaptureManager.swift
//  DockZoom
//
//  窗口缩略图截图：私有 CGSHWCaptureWindowList（可截最小化窗口、规避 Stage Manager 干扰），
//  降级 CGWindowListCreateImage。需要「屏幕录制」权限。
//

import Cocoa

final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    /// 缩略图内存缓存（降采样后体积小；NSCache 自动淘汰）
    private let thumbnailCache = NSCache<NSNumber, NSImage>()

    /// 本次运行是否已请求过权限（避免反复弹系统授权框）
    private var hasRequested = false

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 自动请求权限（仅触发一次系统弹窗）
    func requestPermissionOnce() {
        guard !hasRequested else { return }
        hasRequested = true
        CGRequestScreenCaptureAccess()
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 清空缩略图缓存（窗口内容变化后调用）
    func invalidateThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    /// 截取单个窗口并降采样（原图 2940×1688 会吃掉 19MB/张，必须缩小）
    func captureWindow(windowId: CGWindowID) -> NSImage? {
        let key = NSNumber(value: windowId)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard hasPermission() else { return nil }

        var cgImage: CGImage?
        // 1) 私有 API：可截最小化窗口
        let connectionID = CGSMainConnectionID()
        var id = UInt32(windowId)
        let options: [CGSWindowCaptureOptions] = [
            [.ignoreGlobalClipShape, .bestResolution],
            [.ignoreGlobalClipShape, .nominalResolution],
            [.ignoreGlobalClipShape],
        ]
        for optionSet in options {
            if let captured = CGSHWCaptureWindowList(connectionID, &id, 1, optionSet) as? [CGImage],
               let first = captured.first {
                cgImage = first
                break
            }
        }
        // 2) 运行时降级：CGWindowListCreateImage（新 SDK 头文件已移除，dlsym 探测）
        if cgImage == nil {
            cgImage = runtimeCGWindowListCreateImage(windowId: windowId)
        }
        guard let cgImage, let downscaled = downscale(cgImage, maxWidth: 288) else { return nil }
        thumbnailCache.setObject(downscaled, forKey: key)
        return downscaled
    }

    /// 降采样到 maxWidth（保持宽高比；Retina 下 288px 足够 128pt 卡片清晰显示）
    private func downscale(_ image: CGImage, maxWidth: CGFloat) -> NSImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1.0, maxWidth / max(w, 1))
        let nw = max(Int(w * scale), 1)
        let nh = max(Int(h * scale), 1)
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: nw, height: nh))
    }

    private typealias CGWindowListCreateImageFn = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private func runtimeCGWindowListCreateImage(windowId: CGWindowID) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: CGWindowListCreateImageFn.self)
        return fn(.null, .optionIncludingWindow, windowId, [.boundsIgnoreFraming])?.takeRetainedValue()
    }
}
