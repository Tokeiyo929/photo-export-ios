import Foundation

/// App Group 容器定位：免签重签（Sideloadly/AltStore 系）会把 group 名统一改写
/// （加团队后缀），主 App 和扩展两侧都用同一套候选探测，保证落到同一个容器——
/// SideStore/AltStore 生态通行做法，容器定位失败就降级为不接分享（不影响主流程）。
enum SharedGroup {

    static let baseGroup = "group.com.tokeiyo929.photoexport"

    /// 探测可用的 group 容器（两侧同一套候选，必然落同一个容器）
    static func container(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        var candidates = [baseGroup]
        // 重签后 bundle id 形如 com.tokeiyo929.photoexport.<团队后缀>；group 名同规则
        if let dot = bundleIdentifier.lastIndex(of: "."),
           bundleIdentifier.hasPrefix("com.tokeiyo929.photoexport") {
            let suffix = String(bundleIdentifier[bundleIdentifier.index(after: dot)...])
            if !suffix.isEmpty { candidates.append("\(baseGroup).\(suffix)") }
        }
        for candidate in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                return url
            }
        }
        return nil
    }

    static func inboxDirectory(using root: URL? = nil) -> URL? {
        guard let root = root ?? container() else { return nil }
        let inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    static func queueURL(using root: URL? = nil) -> URL? {
        guard let root = root ?? container() else { return nil }
        return root.appendingPathComponent("share-queue.jsonl")
    }

    /// 扩展侧记账（JSONL 追加）：文件先落盘、再记账，崩溃了也只多不少
    static func enqueue(file: String, note: String?, root: URL? = nil) {
        guard let queue = queueURL(using: root) else { return }
        let entry: [String: String] = ["file": file,
                                       "note": note ?? "",
                                       "at": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? JSONSerialization.data(withJSONObject: [entry]),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: queue) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: queue)
        }
    }
}
