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
                  let tag = json["tag_name"] as? String else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if tag.compare(current, options: .numeric) == .orderedDescending {
                DispatchQueue.main.async {
                    self.notifyNewVersion(tag)
                }
            }
        }
        task.resume()
    }

    private func notifyNewVersion(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = "请前往 GitHub Releases 下载。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
