import Foundation
import ImageIO
import AVFoundation

/// 传送带语义的照片搬运（v4，2026-11-18）：
///   相册/直投/扩展 → 「导入」落点 → **移动**进暂存区 photos/日期/ → 电脑拉取 → 清空。
/// 手机端**没有任何账本**——不算哈希、不写清单、不登记。账在电脑端：
/// pull.py 拉取时逐文件算 SHA-256 落 export-report.csv，按「文件名+大小」跳过已拿到的。
/// 为什么不算哈希：清单哈希链证明的只是「传输没坏」，从未拦住真正的丢失
/// （Live 图变 JPEG 时清单如实记了 JPEG 的哈希，两边一致照样全 PASS）；
/// 而它带来的代价是每个大文件几十秒的等待和整套状态机（「5 个待拉取永远清不掉」）。
enum SharedIn {

    /// 内部状态文件统一归 store（App Support）/logs/：用户可见的 Documents 只留「导入」文件夹
    static func logsDirectory(_ storeURL: URL) -> URL {
        let dir = storeURL.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func extLastURL(_ storeURL: URL) -> URL {
        logsDirectory(storeURL).appendingPathComponent("share-ext-last.txt")
    }

    static func lastResultURL(_ storeURL: URL) -> URL {
        logsDirectory(storeURL).appendingPathComponent("share-last.txt")
    }

    /// 最近一次搬运的现场摘要（首页卡片直接显示）
    static private(set) var lastDiagnostics = ""

    /// 搬运结果：imported=进了暂存区，failed=留在原地等下次
    struct DrainResult {
        var imported = 0
        var failed = 0
    }

    // MARK: - 三个入口（共用 moveStaged）

    /// 分享扩展通道：App Group 收件箱里的文件全部搬走。
    /// **不再读队列**——扩展先落盘再记账，但记账本身出过丢行事故；现在收件箱里有什么
    /// 就搬什么，队列文件直接销毁（账本时代结束）。
    static func drain(storeURL: URL, onFile: ((Int, Int, String) -> Void)? = nil) -> DrainResult {
        forwardExtensionLog(storeURL: storeURL)
        let fm = FileManager.default
        guard let inbox = SharedGroup.inboxDirectory() else {
            ExportLog.write("GROUP drain: \(SharedGroup.lastProbeDescription)")
            lastDiagnostics = "容器未定位：\(SharedGroup.lastProbeDescription)"
            return DrainResult()
        }
        try? fm.removeItem(at: SharedGroup.queueURL())
        let names = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
            .sorted()
        guard !names.isEmpty else {
            lastDiagnostics = "组 \(SharedGroup.resolvedGroupName)：扩展收件箱空"
            return DrainResult()
        }
        let result = staged(names.map { inbox.appendingPathComponent($0) }, storeURL: storeURL,
                            tag: "SHARE", label: "扩展收件箱", onFile: onFile)
        if result.failed > 0 {
            // 失败的留在收件箱，下次再搬（moveStaged 原子：成了就不在原地）
            lastDiagnostics += "；失败 \(result.failed) 个留在收件箱"
        }
        return result
    }

    /// 分享面板「直接打开」（Open in）通道：相册分享面板 App 行点「无损导出」时
    /// 系统把原文件拷进 Documents/Inbox。不依赖 App Group，免费签名也能用。
    static func drainOpenInInbox(documentsURL: URL, storeURL: URL,
                                 onFile: ((Int, Int, String) -> Void)? = nil) -> DrainResult {
        let fm = FileManager.default
        let inbox = documentsURL.appendingPathComponent("Inbox", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return DrainResult() }
        let files = items.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        guard !files.isEmpty else { return DrainResult() }
        return staged(files, storeURL: storeURL, tag: "OPENIN", label: "直投 Inbox", onFile: onFile)
    }

    /// **主通道**：用户在文件 App 里存进「导入」文件夹的照片（相册 → 分享 → 存储到文件）。
    /// 这条链系统递的是原始字节（用户对照实验实锤 IMG_xxxx.HEIC 字节一致），
    /// Live 图=HEIC+MOV 成对。也顺带收 Documents 根的散落文件（存错层级兜底，不收子目录）。
    static func drainImportFolder(documentsURL: URL, storeURL: URL,
                                  onFile: ((Int, Int, String) -> Void)? = nil) -> DrainResult {
        let fm = FileManager.default
        var files: [URL] = []
        let importDir = documentsURL.appendingPathComponent("导入", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil) {
            files += items.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        }
        if let items = try? fm.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            files += items.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        }
        guard !files.isEmpty else { return DrainResult() }
        return staged(files, storeURL: storeURL, tag: "FOLDER", label: "导入夹", onFile: onFile)
    }

    // MARK: - 共用搬运

    /// 逐文件搬进暂存区：读拍摄时间 → 日期目录 → 磁盘防撞名 → 移动（被拒退复制）。
    private static func staged(_ files: [URL], storeURL: URL, tag: String, label: String,
                               onFile: ((Int, Int, String) -> Void)?) -> DrainResult {
        var imported = 0
        var failed = 0
        var firstError = ""
        for (index, url) in files.enumerated() {
            onFile?(index + 1, files.count, url.lastPathComponent)
            do {
                try moveStaged(url, storeURL: storeURL)
                imported += 1
            } catch {
                failed += 1
                if firstError.isEmpty { firstError = "\(url.lastPathComponent): \(error.localizedDescription)" }
                ExportLog.write("\(tag) FAIL \(url.lastPathComponent): \(error)")
            }
        }
        ExportLog.write("\(tag) staged=\(imported) fail=\(failed) firstErr=\(firstError)")
        lastDiagnostics = "\(label) \(files.count) 个 → 已入暂存 \(imported)" + (failed > 0 ? " 失败 \(failed)" : "")
            + (firstError.isEmpty ? "" : "；首个错误 \(firstError)")
        return DrainResult(imported: imported, failed: failed)
    }

    /// 单文件：读拍摄时间定目录 → 防撞名落盘 → 移动进 photos/日期/。
    /// 抛错 = 文件留在原地（收件箱/导入夹），下次再搬。
    static func moveStaged(_ source: URL, storeURL: URL) throws {
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "m4v"].contains(ext)
        // 拍摄时间必须在搬走前读：图片读 EXIF，视频读 QuickTime creationDate，都没有退文件时间
        let shotDate: Date? = isVideo ? videoCreationDate(of: source) : exifDate(of: source)
        let fileDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
        let (directory, _) = ExportPlanner.dateDirectory(creationDate: shotDate, fileDate: fileDate,
                                                         calendar: .current)
        let fullDir = "photos/" + directory
        let targetDir = storeURL.appendingPathComponent(fullDir, isDirectory: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let (_, target) = diskSafeName(source.lastPathComponent, in: targetDir)
        do {
            try fm.moveItem(at: source, to: target)
        } catch {
            // 少数组权限形态下跨容器 rename 被拒（Operation not permitted）：
            // 退回复制+删原件，字节不变
            try fm.copyItem(at: source, to: target)
            try? fm.removeItem(at: source)
        }
        let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? Int64) ?? 0
        ExportLog.write(String(format: "STAGE %@ → %@ %lld bytes", source.lastPathComponent, fullDir + "/" + (target.lastPathComponent), size))
    }

    /// 落盘前的真实文件系统消歧：名字已被占就在扩展名前加 " (n)"。
    /// 返回 (最终文件名, 目标 URL)；目标保证不存在。触发时落日志留证。
    static func diskSafeName(_ fileName: String, in dir: URL) -> (String, URL) {
        let fm = FileManager.default
        var target = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: target.path) else { return (fileName, target) }
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = fileName
        var n = 0
        repeat {
            n += 1
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            target = dir.appendingPathComponent(candidate)
        } while fm.fileExists(atPath: target.path)
        ExportLog.write("STAGE name-collision \(fileName) → \(candidate)")
        return (candidate, target)
    }

    // MARK: - 时间与日志

    private static func exifDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }

    private static func videoCreationDate(of url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = AVMetadataItem.metadataItems(from: asset.metadata,
                                                      filteredByIdentifier: .commonIdentifierCreationDate).first else { return nil }
        return item.dateValue
    }

    /// 扩展的现场日志转写进主日志：分享扩展崩了没有任何报告渠道，这是它把
    /// 证据带出设备的唯一通道（转写完即删，下次分享重新积累）。
    private static func forwardExtensionLog(storeURL: URL) {
        guard let root = SharedGroup.container(),
              let raw = try? String(contentsOf: root.appendingPathComponent("share-log.txt"),
                                    encoding: .utf8),
              !raw.isEmpty else { return }
        var last = ""
        for line in raw.split(separator: "\n") {
            ExportLog.write(String(line))
            if line.contains("EXT ") { last = String(line) }
        }
        // 扩展最后一行落 logs（首页卡片显示）：主 App 看到 0 项时，
        // 对比「EXT container resolved=…」就能判断是不是写了另一个容器
        try? Data(last.utf8).write(to: extLastURL(storeURL))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("share-log.txt"))
    }
}
