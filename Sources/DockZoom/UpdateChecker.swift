//
//  UpdateChecker.swift
//  DockZoom
//

import Foundation
import AppKit

final class UpdateChecker {
    static let shared = UpdateChecker()

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "LastUpdateCheckDate"
    private let repo = "Namelessying/DockZoom"

    /// 检查更新（24h 防抖）
    func check(manual: Bool) {
        if !manual, let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var tag = json["tag_name"] as? String else {
                DebugLogger.shared.log("检查更新失败: \(error?.localizedDescription ?? "无数据")")
                return
            }
            // 版本号来源：优先 bundle Info.plist，裸二进制运行时用构建时生成的常量
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? kDockZoomVersion
            // 去掉 tag 的 "v" 前缀（"v0.2.4" 与 "0.2.4" 直接 numeric 比较会恒判定"新版本"）
            if tag.hasPrefix("v") { tag.removeFirst() }
            DebugLogger.shared.log("检查更新: 最新=\(tag) 当前=\(current)")
            if Self.isNewer(tag, than: current) {
                DispatchQueue.main.async {
                    self.notifyNewVersion(tag)
                }
            }
        }
        task.resume()
    }

    /// 版本号逐段数值比较（"0.2.4" > "0.2.3"；相等/降级不算新版本）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        guard !pa.isEmpty, !pb.isEmpty else { return false }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va > vb { return true }
            if va < vb { return false }
        }
        return false
    }

    private func notifyNewVersion(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = "请前往 GitHub Releases 下载。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
