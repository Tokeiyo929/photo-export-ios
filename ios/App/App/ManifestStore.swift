import Foundation

/// 导出清单的一行。status: "OK"（导出成功且哈希一致）/ "FAIL"（失败，note 记原因）。
/// 断点续跑的依据：OK 的 relative_path 下次跳过，FAIL 下次重试。
struct ManifestRow {
    var relativePath: String = ""
    var size: Int64 = 0
    var sha256: String = ""
    var dateSource: String = ""
    var assetId: String = ""
    var mediaType: String = ""
    var favorite: Bool = false
    var status: String = ""
    var exportedAt: String = ""
    var note: String = ""
}

/// manifest.csv（UTF-8 带 BOM，Excel 直接打开不乱码）。
/// 列顺序固定，PC 端 pull.py / verify.py 按表头解析。
enum ManifestStore {

    static let header = ["relative_path", "size", "sha256", "date_source",
                         "asset_id", "media_type", "favorite", "status", "exported_at", "note"]

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func now() -> String { isoFormatter.string(from: Date()) }

    // MARK: - CSV 编解码（RFC4180 风格：含逗号/引号的字段加引号，内部引号翻倍）

    static func escape(_ field: String) -> String {
        let cleaned = field.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if cleaned.contains(",") || cleaned.contains("\"") {
            return "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cleaned
    }

    /// 解析单行 CSV。空白行返回 nil；引号状态机容忍 \r。
    static func parseLine(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        var sawAnyChar = false
        while index < line.endIndex {
            sawAnyChar = true
            let char = line[index]
            if inQuotes {
                if char == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                fields.append(current)
                current = ""
            } else if char != "\r" {
                current.append(char)
            }
            index = line.index(after: index)
        }
        guard sawAnyChar else { return nil }
        fields.append(current)
        return fields
    }

    static func csvLine(for row: ManifestRow) -> String {
        [row.relativePath, String(row.size), row.sha256, row.dateSource, row.assetId,
         row.mediaType, row.favorite ? "1" : "0", row.status, row.exportedAt, row.note]
            .map(escape)
            .joined(separator: ",")
    }

    static func row(from fields: [String]) -> ManifestRow? {
        guard fields.count >= header.count else { return nil }
        var row = ManifestRow()
        row.relativePath = fields[0]
        row.size = Int64(fields[1]) ?? 0
        row.sha256 = fields[2]
        row.dateSource = fields[3]
        row.assetId = fields[4]
        row.mediaType = fields[5]
        row.favorite = fields[6] == "1"
        row.status = fields[7]
        row.exportedAt = fields[8]
        row.note = fields[9]
        guard !row.relativePath.isEmpty, row.status == "OK" || row.status == "FAIL" else { return nil }
        return row
    }

    // MARK: - 读写

    /// 读整个清单。返回行与解析失败行数（表头/空白行不算失败）。
    static func load(url: URL) -> (rows: [ManifestRow], malformed: Int) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return ([], 0) }
        var rows: [ManifestRow] = []
        var malformed = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let fields = parseLine(String(line)) else { continue }
            if fields.count == header.count && fields[0] == "relative_path" { continue } // 表头
            if let row = row(from: fields) { rows.append(row) } else { malformed += 1 }
        }
        return (rows, malformed)
    }

    /// 同一 relative_path 多行时以最后一行为准（追加式日志的语义）。
    static func rowDictionary(of rows: [ManifestRow]) -> [String: ManifestRow] {
        var dict: [String: ManifestRow] = [:]
        for row in rows { dict[row.relativePath] = row }
        return dict
    }

    static func okPaths(of rows: [ManifestRow]) -> Set<String> {
        Set(rowDictionary(of: rows).filter { $0.value.status == "OK" }.keys)
    }

    /// 追加若干行；文件不存在时先写 BOM + 表头。
    static func append(url: URL, rows: [ManifestRow]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try writeAll(url: url, rows: [])
        }
        var payload = ""
        for row in rows { payload += csvLine(for: row) + "\n" }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = payload.data(using: .utf8) { try handle.write(contentsOf: data) }
    }

    /// 全量重写（BOM + 表头 + 行）。
    static func writeAll(url: URL, rows: [ManifestRow]) throws {
        var text = "\u{FEFF}" + header.joined(separator: ",") + "\n"
        for row in rows { text += csvLine(for: row) + "\n" }
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
