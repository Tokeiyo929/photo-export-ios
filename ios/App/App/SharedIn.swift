import Foundation
import ImageIO
import AVFoundation

/// 分享导入落位：把 App Group 收件箱里的文件搬进 Documents（按拍摄时间归档）
/// 并登记进清单——让相册「分享→无损导出」的照片走同一条哈希证明链，
/// pull.py 拉取校验/清理与扫描导出的文件完全同权（PC 端零改动）。
enum SharedIn {

    static func drain(documentsURL: URL, manifestURL: URL) -> Int {
        let fm = FileManager.default
        guard let inbox = SharedGroup.inboxDirectory(),
              let queueURL = SharedGroup.queueURL() else { return 0 }

        // 读队列（崩溃安全：文件先落盘再记账，这行没有就当下次再收）
        guard let raw = try? String(contentsOf: queueURL, encoding: .utf8) else { return 0 }
        var entries: [(file: String, note: String)] = []
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let file = obj["file"] else { continue }
            entries.append((file, obj["note"] ?? ""))
        }
        guard !entries.isEmpty else { return 0 }

        // 清单一次读入：重复内容守卫用（同名+同哈希 → 分享两次同一张）
        let (rows, _) = ManifestStore.load(url: manifestURL)
        var known = Set(rows.map { "\($0.sha256)|\($0.relativePath.split(separator: "/").last.map(String.init) ?? "")" })

        // 重名去重的「已占用」集合：Documents 里现有文件 + 清单里出现过的路径（与引擎同口径小写键）
        var used = Set(rows.map { $0.relativePath.lowercased() })
        if let walker = fm.enumerator(at: documentsURL, includingPropertiesForKeys: nil) {
            let prefix = documentsURL.path + "/"
            for case let url as URL in walker {
                used.insert(url.path.replacingOccurrences(of: prefix, with: "").lowercased())
            }
        }

        var imported = 0
        var skipped = 0
        var failed = 0
        var pending: [ManifestRow] = []
        var leftovers: [String] = []
        let iso = ISO8601DateFormatter()

        for entry in entries {
            let source = inbox.appendingPathComponent(entry.file)
            guard fm.fileExists(atPath: source.path) else {
                continue // 队列里有、文件没了（上次搬到一半崩了）——直接销账
            }
            do {
                let row = try importFile(source, documentsURL: documentsURL, inboxFile: entry.file,
                                         known: &known, used: &used, note: entry.note, iso: iso)
                if let row {
                    pending.append(row)
                    let base = row.relativePath.split(separator: "/").last.map(String.init) ?? entry.file
                    known.insert("\(row.sha256)|\(base)")
                    imported += 1
                    try? fm.removeItem(at: source)
                } else {
                    skipped += 1 // 重复内容（同一张照片分享两次）
                    try? fm.removeItem(at: source)
                }
            } catch {
                failed += 1
                leftovers.append(entry.file) // 留在收件箱，下次再试
            }
        }

        if !pending.isEmpty {
            try? ManifestStore.append(url: manifestURL, rows: pending)
            ExportLog.write("SHARE-IMPORT ok=\(imported) skip=\(skipped) fail=\(failed)")
        }
        // 重写队列 = 只剩没搬成的（文件不在的自动销账）
        rewriteQueue(leftovers, entries: entries, queueURL: queueURL, iso: iso)
        return imported
    }

    /// 单文件：算哈希→定归档目录（EXIF 拍摄时间优先）→消歧落位→出清单行。
    /// 返回 nil 表示重复内容（跳过）；抛错表示搬不动（留在收件箱）。
    private static func importFile(_ source: URL, documentsURL: URL, inboxFile: String,
                                   known: inout Set<String>, used: inout Set<String>,
                                   note: String, iso: ISO8601DateFormatter) throws -> ManifestRow? {
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "m4v"].contains(ext)

        // 重复内容守卫：同名+同哈希已在清单里 → 跳过
        let sha = try FileHasher.sha256(of: source)
        if known.contains("\(sha)|\(inboxFile)") {
            return nil
        }

        // 拍摄时间：图片读 EXIF，视频读 QuickTime creationDate，都没有退文件时间
        let shotDate: Date? = isVideo ? videoCreationDate(of: source) : exifDate(of: source)
        let fileDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
        let (directory, dateSource) = ExportPlanner.dateDirectory(creationDate: shotDate, fileDate: fileDate,
                                                                  calendar: .current)

        let targetDir = documentsURL.appendingPathComponent(directory, isDirectory: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let fileName = ExportPlanner.disambiguate(fileName: source.lastPathComponent,
                                                  directory: directory, used: &used)
        let target = targetDir.appendingPathComponent(fileName)
        try fm.moveItem(at: source, to: target)

        let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? Int64) ?? 0
        return ManifestRow(relativePath: directory + "/" + fileName,
                           size: size,
                           sha256: sha,
                           dateSource: dateSource.rawValue,
                           assetId: "", // 分享导入拿不到 PHAsset 绑定，链路靠哈希本身
                           mediaType: isVideo ? "video" : "photo",
                           favorite: false,
                           status: "OK",
                           exportedAt: iso.string(from: Date()),
                           note: note.isEmpty ? "相册分享导入" : note + "（相册分享导入）")
    }

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
                                                      filteredByIdentifier: .commonIdentifierCreationDate).first,
              let date = try? item.load(.dateValue) else { return nil }
        return date
    }

    /// 重写队列 = 只剩没搬成的（文件不在的自动销账）
    private static func rewriteQueue(_ leftovers: [String], entries: [(file: String, note: String)],
                                     queueURL: URL, iso: ISO8601DateFormatter) {
        guard !leftovers.isEmpty else {
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        let lines = leftovers.map { file -> String in
            let note = entries.first(where: { $0.file == file })?.note ?? ""
            let obj: [String: String] = ["file": file, "note": note, "at": iso.string(from: Date())]
            return String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(),
                          encoding: .utf8) ?? ""
        }.filter { !$0.isEmpty }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: queueURL)
    }
}
