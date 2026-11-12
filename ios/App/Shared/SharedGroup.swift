import Foundation

/// App Group 容器定位：免签重签（Sideloadly/AltStore/SideStore 系）会把 group 名
/// 统一改写（拼团队后缀等规则各家不同、还随版本变），猜名字不可靠——
/// **profile 是唯一真相**：重签工具打进包里的 embedded.mobileprovision 的
/// Entitlements 就是最终生效的组名清单（SideStore ResignAppOperation 同款做法，
/// 它重写 Info.plist 里的组引用时也以 profile.entitlements 为准）。
/// 主 App 和扩展两侧共用这套探测，各自读自己的 profile，必然落到同一个容器。
enum SharedGroup {

    static let baseGroup = "group.com.tokeiyo929.photoexport"

    /// 最近一次 container() 探测的结论（诊断用，主 App 写进 ExportLog）
    static private(set) var lastProbeDescription = "not probed"

    private static var resolvedContainer: URL?

    /// 组名真值的读取规则（两侧一致，必然落同一个容器）：
    /// 扩展优先读**主 App** 的 profile（沿 .appex→PlugIns→.app 路径）——重签工具
    /// 可能只在主 App 里嵌 profile；主 App 读自己的。都取不到再退自己那份。
    private static func provisionedGroupNames() -> [String] {
        var profiles: [URL] = []
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let parentProfile = Bundle.main.bundleURL
                .deletingLastPathComponent()              // PlugIns/
                .deletingLastPathComponent()              // 主 .app/
                .appendingPathComponent("embedded.mobileprovision")
            profiles.append(parentProfile)
        }
        if let own = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") {
            profiles.append(URL(fileURLWithPath: own))
        }
        var names: [String] = []
        for profile in profiles {
            for name in groupsInProfile(at: profile) where name.hasPrefix("group.") && !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// 解析单个 profile（CMS/DER 包着 XML plist，按字节扫出 plist 段）
    private static func groupsInProfile(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return [] }
        let xml = data.subdata(in: start.lowerBound ..< end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
    }

    /// 探测可用的 group 容器（两侧同一套逻辑：先真值后兜底，必然落同一个容器）
    static func container(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        if let resolved = resolvedContainer { return resolved }
        let fm = FileManager.default

        // 1) 真值：重签工具下发的 profile 里实际列出的组名（逐个试，第一个能开的就用）
        var tried: [String] = []
        for name in provisionedGroupNames() where name.hasPrefix("group.") {
            tried.append(name)
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: name) {
                resolvedContainer = url
                lastProbeDescription = "resolved=\(name) (profile)"
                return url
            }
        }

        // 2) 兜底：旧启发式（profile 缺失/解析失败时）——原签名直装场景 profile 反而不含组
        var candidates = [baseGroup]
        if let dot = bundleIdentifier.lastIndex(of: "."),
           bundleIdentifier.hasPrefix("com.tokeiyo929.photoexport") {
            let suffix = String(bundleIdentifier[bundleIdentifier.index(after: dot)...])
            if !suffix.isEmpty { candidates.append("\(baseGroup).\(suffix)") }
        }
        for name in candidates {
            tried.append(name + "~")
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: name) {
                resolvedContainer = url
                lastProbeDescription = "resolved=\(name) (heuristic)"
                return url
            }
        }

        lastProbeDescription = "FAIL tried=[\(tried.joined(separator: ", "))]"
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

    /// 扩展侧现场日志（追加写 group 根目录 share-log.txt）：
    /// 分享扩展崩了没有任何报告渠道（连崩溃报告都难拿），把收到的提供者类型、
    /// 字节数、错误逐行落在这里；主 App 下次 drain 时转写进 ExportLog 带出设备。
    static func appendLog(_ message: String, root: URL? = nil) {
        guard let root = root ?? container() else { return }
        let url = root.appendingPathComponent("share-log.txt")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
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
