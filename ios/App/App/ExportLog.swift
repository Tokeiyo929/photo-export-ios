import Foundation

/// 轻量文件日志：追加写 Documents/export-log.txt（超 2MB 轮转为 export-log.old.txt）。
/// 为什么必须有：真机「闪退」往往根本不留崩溃报告——挂死被用户划掉、盘满被系统
/// 静默终止、JetsamEvent 也可能缺失。一份带时间戳的工作日志（每个阶段、每个文件、
/// 每次护栏触发）随 pull.py 回到电脑，才能定位卡在哪一步。
enum ExportLog {

    private static let maxBytes: Int64 = 2_000_000
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("export-log.txt")
    }

    /// 线程安全；写失败静默（日志不能反过来影响导出）。
    static func write(_ message: String) {
        let line = formatter.string(from: Date()) + " " + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        let url = logURL
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int64) ?? 0 > maxBytes {
            let old = url.deletingPathExtension().appendingPathExtension("old.txt")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            try? Data("photo-export log\n".utf8).write(to: url, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
        }
    }
}
