import Foundation

/// App Group 容器定位：免签重签（Sideloadly/AltStore/SideStore 系）下免费团队
/// 常常认领不了原始组名，签名端会注册「带团队后缀的组」写进两份 profile——
/// 所以**profile 是唯一真相**（SideStore ResignAppOperation 同款），且必须
/// 主 App 和扩展两份 profile 都读：交集才是保证同容器的组名。
/// 候选/采纳规则对齐 classday-ios 的免签同场景实现：
/// 原名 → 两份 profile 交集 → 并集 → 重签生态常见改写形（拼 TeamID/bundle id），
/// 采纳第一个 containerURL 能开 **且** UserDefaults(suiteName:) 能落笔回读的。
enum SharedGroup {

    static let baseGroup = "group.com.tokeiyo929.photoexport"

    /// 最近一次 container() 探测的结论（诊断用，失败弹窗/主 App 日志都带它）
    static private(set) var lastProbeDescription = "not probed"

    private static var resolvedContainer: URL?

    // MARK: - profile 解析

    /// 主 App bundle 的 profile（两侧都能读到：扩展沿 .appex→PlugIns→.app）
    private static var mainAppProfileURL: URL {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return Bundle.main.bundleURL
                .deletingLastPathComponent()              // PlugIns/
                .deletingLastPathComponent()              // 主 .app/
                .appendingPathComponent("embedded.mobileprovision")
        }
        return Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
    }

    /// 对侧（appex）profile 的清单：主 App 从 PlugIns/ 里枚举；扩展自己那份就是 own
    private static var sideProfileURLs: [URL] {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else { return [] }
            return [URL(fileURLWithPath: path)]
        }
        let plugins = Bundle.main.bundleURL.appendingPathComponent("PlugIns")
        guard let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "appex" }
            .map { $0.appendingPathComponent("embedded.mobileprovision") }
    }

    /// 解析单份 profile（CMS/DER 包着 XML plist，按字节扫出 plist 段）里的组名与 TeamID
    private static func groupsAndTeams(in url: URL) -> (groups: [String], teams: [String]) {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return ([], []) }
        let xml = data.subdata(in: start.lowerBound ..< end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any] else { return ([], []) }
        let groups = ((plist["Entitlements"] as? [String: Any])?["com.apple.security.application-groups"] as? [String]) ?? []
        let teams = (plist["TeamIdentifier"] as? [String]) ?? []
        return (groups.filter { $0.hasPrefix("group.") }, teams.filter { !$0.isEmpty })
    }

    // MARK: - 候选与采纳

    /// 探测可用的 group 容器（两侧同一套逻辑，必然落同一个容器）
    static func container(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        if let resolved = resolvedContainer { return resolved }

        let appSide = groupsAndTeams(in: mainAppProfileURL)
        var extSideGroups: [String] = []
        var teams = appSide.teams
        for url in sideProfileURLs {
            let parsed = groupsAndTeams(in: url)
            extSideGroups += parsed.groups
            for team in parsed.teams where !teams.contains(team) { teams.append(team) }
        }

        // 候选清单：原名 → 交集（两份都列 = 保证同容器）→ 并集（某份缺失/解析失败时）→ 改写形
        var candidates = [baseGroup]
        for name in appSide.groups where extSideGroups.contains(name) && !candidates.contains(name) {
            candidates.append(name)
        }
        for name in appSide.groups + extSideGroups where !candidates.contains(name) {
            candidates.append(name)
        }
        let rawBase = String(baseGroup.dropFirst("group.".count))
        for team in teams {
            for form in ["\(baseGroup).\(team)", "group.\(team).\(rawBase)",
                         "group.\(bundleIdentifier)", "group.\(bundleIdentifier).\(team)",
                         "group.\(team).\(bundleIdentifier)"] {
                if !candidates.contains(form) { candidates.append(form) }
            }
        }

        let fm = FileManager.default
        var tried: [String] = []
        var roundTripFailed: [String] = []
        for name in candidates {
            tried.append(name)
            guard let url = fm.containerURL(forSecurityApplicationGroupIdentifier: name) else { continue }
            // 双确认：容器能开 + UserDefaults 能落笔回读（classday 同款 round-trip）
            let defaults = UserDefaults(suiteName: name)
            defaults?.set(true, forKey: "photoexport.group.probe")
            guard defaults?.bool(forKey: "photoexport.group.probe") == true else {
                roundTripFailed.append(name)
                continue
            }
            defaults?.removeObject(forKey: "photoexport.group.probe")
            resolvedContainer = url
            lastProbeDescription = "resolved=\(name)（主App profile \(appSide.groups.count) 组 / appex profile \(extSideGroups.count) 组）"
            return url
        }
        lastProbeDescription = "FAIL 主AppProfile=\(appSide.groups) appexProfile=\(extSideGroups) "
            + "tried=[\(tried.joined(separator: ", "))]"
            + (roundTripFailed.isEmpty ? "" : " roundTripFail=[\(roundTripFailed.joined(separator: ", "))]")
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
