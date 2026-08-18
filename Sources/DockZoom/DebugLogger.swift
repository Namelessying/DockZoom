//
//  DebugLogger.swift
//  DockZoom
//

import Foundation
import AppKit

final class DebugLogger {
    static let shared = DebugLogger()

    private let queue = DispatchQueue(label: "com.dockzoom.logger")
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: UInt64 = 2 * 1024 * 1024

    /// 用户设置里的日志开关（默认开）
    var enabled: Bool = true

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DockZoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dockzoom.log")
        rotateIfNeeded()
    }

    func log(_ message: String) {
        guard enabled else { return }
        let line = "[\(Self.timestamp())] \(message)\n"
        NSLog("DockZoom: \(message)")
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    func openLogDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func write(_ line: String) {
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            if fileHandle == nil {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                fileHandle = try? FileHandle(forWritingTo: fileURL)
            }
            fileHandle?.seekToEndOfFile()
        }
        try? fileHandle?.write(contentsOf: Data(line.utf8))
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
              size > maxFileSize else { return }
        try? fileHandle?.close()
        fileHandle = nil
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
