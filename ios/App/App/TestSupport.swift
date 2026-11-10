import Foundation
import CryptoKit

struct TestOutcome {
    let name: String
    let passed: Bool
    let detail: String
}

/// 纯 Foundation/CryptoKit 自测：被 tests/CoreTests.swift（L1 swiftc 隔离）
/// 和 App 内 -autoTest 共用。只测纯逻辑，不碰相册。
enum TestSupport {

    static func runSelfTests() -> [TestOutcome] {
        var outcomes: [TestOutcome] = []
        func record(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                outcomes.append(TestOutcome(name: name, passed: true, detail: ""))
            } catch {
                outcomes.append(TestOutcome(name: name, passed: false, detail: String(describing: error)))
            }
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "TestSupport", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func requireUnwrap<T>(_ value: T?, _ message: String) throws -> T {
            guard let value else { throw NSError(domain: "TestSupport", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: message]) }
            return value
        }

        // MARK: 日期归档

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 10, minute: 30))!
        }

        record("日期目录: 拍摄时间格式 yyyy/yyyy-MM-dd") {
            let result = ExportPlanner.dateDirectory(creationDate: date(2026, 3, 15),
                                                     fileDate: nil, calendar: calendar)
            try require(result.0 == "2026/2026-03-15", "得到 \(result.0)")
            try require(result.1 == .creation, "来源应为 creation，得到 \(result.1)")
        }
        record("日期目录: 跨年月日补零") {
            let result = ExportPlanner.dateDirectory(creationDate: date(1999, 1, 2),
                                                     fileDate: nil, calendar: calendar)
            try require(result.0 == "1999/1999-01-02", "得到 \(result.0)")
        }
        record("日期目录: 无拍摄时间回退文件时间") {
            let result = ExportPlanner.dateDirectory(creationDate: nil,
                                                     fileDate: date(2025, 12, 31), calendar: calendar)
            try require(result.0 == "2025/2025-12-31" && result.1 == .fileTime, "得到 \(result.0)/\(result.1)")
        }
        record("日期目录: 全无 → UNDATED") {
            let result = ExportPlanner.dateDirectory(creationDate: nil, fileDate: nil, calendar: calendar)
            try require(result.0 == "UNDATED" && result.1 == .undated, "得到 \(result.0)/\(result.1)")
        }
        record("日期目录: 异常年份守卫") {
            try require(ExportPlanner.directoryString(for: date(1800, 5, 5), calendar: calendar) == "UNDATED",
                        "1800 年应判为异常")
        }

        // MARK: 重名消歧

        record("重名: 同目录第二次加 (1)") {
            var used: Set<String> = []
            let first = ExportPlanner.disambiguate(fileName: "IMG_0001.HEIC", directory: "2026/2026-03-15", used: &used)
            let second = ExportPlanner.disambiguate(fileName: "IMG_0001.HEIC", directory: "2026/2026-03-15", used: &used)
            try require(first == "IMG_0001.HEIC", "第一次应保留原名，得到 \(first)")
            try require(second == "IMG_0001 (1).HEIC", "第二次应为 IMG_0001 (1).HEIC，得到 \(second)")
        }
        record("重名: 第三次加 (2)，大小写不敏感") {
            var used: Set<String> = []
            _ = ExportPlanner.disambiguate(fileName: "IMG_0001.heic", directory: "2026/2026-03-15", used: &used)
            _ = ExportPlanner.disambiguate(fileName: "IMG_0001.HEIC", directory: "2026/2026-03-15", used: &used)
            let third = ExportPlanner.disambiguate(fileName: "img_0001.Heic", directory: "2026/2026-03-15", used: &used)
            try require(third == "IMG_0001 (2).Heic" || third == "img_0001 (2).Heic",
                        "前两名已被占（含大小写变体），第三个应加 (2)，得到 \(third)")
        }
        record("重名: 不同目录不冲突") {
            var used: Set<String> = []
            _ = ExportPlanner.disambiguate(fileName: "IMG_0001.HEIC", directory: "2026/2026-03-15", used: &used)
            let other = ExportPlanner.disambiguate(fileName: "IMG_0001.HEIC", directory: "2026/2026-03-16", used: &used)
            try require(other == "IMG_0001.HEIC", "不同目录应保留原名，得到 \(other)")
        }
        record("重名: 无扩展名文件") {
            var used: Set<String> = []
            _ = ExportPlanner.disambiguate(fileName: "README", directory: "UNDATED", used: &used)
            let second = ExportPlanner.disambiguate(fileName: "README", directory: "UNDATED", used: &used)
            try require(second == "README (1)", "得到 \(second)")
        }
        record("规划: 同日两资产重名展开 + Live Photo 双文件保留") {
            let assets = [
                AssetInfo(id: "a", mediaType: "photo", isLive: false, isFavorite: false,
                          creationDate: date(2026, 3, 15), fileDate: nil,
                          resources: [ResourceInfo(fileName: "IMG_0001.HEIC", size: 10)]),
                AssetInfo(id: "b", mediaType: "photo", isLive: true, isFavorite: false,
                          creationDate: date(2026, 3, 15), fileDate: nil,
                          resources: [ResourceInfo(fileName: "IMG_0001.HEIC", size: 20),
                                      ResourceInfo(fileName: "IMG_0001.MOV", size: 30)]),
            ]
            let planned = ExportPlanner.plan(assets: assets, calendar: calendar)
            try require(planned.count == 3, "应有 3 个文件，得到 \(planned.count)")
            try require(planned[0].relativePath == "2026/2026-03-15/IMG_0001.HEIC", "得到 \(planned[0].relativePath)")
            try require(planned[1].relativePath == "2026/2026-03-15/IMG_0001 (1).HEIC", "得到 \(planned[1].relativePath)")
            try require(planned[2].relativePath == "2026/2026-03-15/IMG_0001.MOV", "得到 \(planned[2].relativePath)")
            try require(ExportPlanner.totalBytes(assets: assets) == 60, "总大小应为 60")
        }

        // MARK: SHA-256

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pe-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        func tempFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            try Data(bytes).write(to: url, options: .atomic)
            return url
        }

        record("哈希: SHA256(abc) 已知向量") {
            let url = try tempFile("abc.bin", Array("abc".utf8))
            let hash = try FileHasher.sha256(of: url)
            try require(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                        "得到 \(hash)")
        }
        record("哈希: 空文件已知向量") {
            let url = try tempFile("empty.bin", [])
            let hash = try FileHasher.sha256(of: url)
            try require(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                        "得到 \(hash)")
        }
        record("哈希: 多块流式与整块一致") {
            var bytes = [UInt8]()
            bytes.reserveCapacity(2 * FileHasher.chunkSize + 12345)
            var seed: UInt8 = 7
            for _ in 0..<(2 * FileHasher.chunkSize + 12345) {
                seed = seed &* 31 &+ 17
                bytes.append(seed)
            }
            let url = try tempFile("big.bin", bytes)
            let streaming = try FileHasher.sha256(of: url)
            let whole = FileHasher.hexEncode(Array(SHA256.hash(data: Data(bytes))))
            try require(streaming == whole, "流式 \(streaming) != 整块 \(whole)")
        }

        // MARK: manifest CSV

        func tempCSV(_ name: String) -> URL {
            tempDir.appendingPathComponent(name)
        }

        record("清单: 写读往返（逗号/引号/中文）") {
            let url = tempCSV("m1.csv")
            var row = ManifestRow()
            row.relativePath = "2026/2026-03-15/照片, 一\"奇\".HEIC"
            row.size = 123
            row.sha256 = "ab" + String(repeating: "0", count: 62)
            row.dateSource = "creation"
            row.assetId = "ABC-1"
            row.mediaType = "photo"
            row.favorite = true
            row.status = "OK"
            row.exportedAt = "2026-11-10T08:00:00Z"
            row.note = "备注,含\"引号\"与\n换行"
            try ManifestStore.writeAll(url: url, rows: [row])
            let loaded = ManifestStore.load(url: url)
            try require(loaded.malformed == 0, "malformed=\(loaded.malformed)")
            try require(loaded.rows.count == 1, "行数 \(loaded.rows.count)")
            let back = loaded.rows[0]
            try require(back.relativePath == row.relativePath, "路径不符 \(back.relativePath)")
            try require(back.note == "备注,含\"引号\"与 换行", "note 不符 \(back.note)")
            try require(back.favorite && back.size == 123 && back.status == "OK", "标量字段不符")
        }
        record("清单: BOM 与表头") {
            let url = tempCSV("m2.csv")
            try ManifestStore.writeAll(url: url, rows: [])
            let raw = try Data(contentsOf: url)
            try require(raw.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]), "缺少 UTF-8 BOM")
            let text = String(data: raw.dropFirst(3), encoding: .utf8) ?? ""
            try require(text.hasPrefix(ManifestStore.header.joined(separator: ",")), "表头不符")
        }
        record("清单: 追加保留旧行且不重复表头") {
            let url = tempCSV("m3.csv")
            var first = ManifestRow()
            first.relativePath = "a/one.HEIC"; first.status = "OK"; first.sha256 = String(repeating: "a", count: 64)
            try ManifestStore.writeAll(url: url, rows: [first])
            var second = ManifestRow()
            second.relativePath = "a/two.HEIC"; second.status = "FAIL"; second.note = "写入中断"
            try ManifestStore.append(url: url, rows: [second])
            let loaded = ManifestStore.load(url: url)
            try require(loaded.rows.count == 2, "行数 \(loaded.rows.count)")
            try require(loaded.rows[0].relativePath == "a/one.HEIC" && loaded.rows[1].status == "FAIL", "内容不符")
        }
        record("清单: 同路径多行以最后一行为准") {
            var old = ManifestRow(); old.relativePath = "a/one.HEIC"; old.status = "FAIL"
            var new = ManifestRow(); new.relativePath = "a/one.HEIC"; new.status = "OK"
            let dict = ManifestStore.rowDictionary(of: [old, new])
            try require(dict["a/one.HEIC"]?.status == "OK", "应取最后一行")
            try require(ManifestStore.okPaths(of: [old, new]) == ["a/one.HEIC"], "okPaths 不符")
        }
        record("清单: 损坏行计数") {
            let url = tempCSV("m4.csv")
            let text = "\u{FEFF}" + ManifestStore.header.joined(separator: ",") + "\n"
                + "bad-line-only\n"
                + "a/one.HEIC,1,,creation,id,photo,0,OK,2026-01-01T00:00:00Z,\n"
            try text.data(using: .utf8)!.write(to: url, options: .atomic)
            let loaded = ManifestStore.load(url: url)
            try require(loaded.rows.count == 1 && loaded.malformed == 1,
                        "rows=\(loaded.rows.count) malformed=\(loaded.malformed)")
        }
        record("清单: parseLine 引号状态机") {
            let fields = ManifestStore.parseLine("\"a,\"\"b\"\",c\",2,,x")
            try require(fields?.count == 4, "字段数 \(String(describing: fields?.count))")
            try require(fields?[0] == "a,\"b\",c", "第一个字段 \(String(describing: fields?[0]))")
            try require(fields?[1] == "2" && fields?[2] == "" && fields?[3] == "x", "后续字段不符")
        }
        record("清单: PULLED 状态可解析且计入 donePaths") {
            var row = ManifestRow()
            row.relativePath = "2025/2025-06-01/IMG_0001.HEIC"
            row.sha256 = String(repeating: "3", count: 64)
            row.status = "PULLED"
            let fields = try requireUnwrap(ManifestStore.parseLine(ManifestStore.csvLine(for: row)),
                                           "PULLED 行应可序列化解析")
            let parsed = try requireUnwrap(ManifestStore.row(from: fields), "PULLED 应可解析")
            try require(parsed.status == "PULLED", "状态应为 PULLED，得到 \(parsed.status)")
            try require(parsed.relativePath == row.relativePath, "PULLED 行字段不符")
        }
        record("清单: donePaths 含 OK 与 PULLED，不含 FAIL") {
            var ok = ManifestRow(); ok.relativePath = "a/ok.HEIC"; ok.status = "OK"
            var pulled = ManifestRow(); pulled.relativePath = "a/pulled.HEIC"; pulled.status = "PULLED"
            var fail = ManifestRow(); fail.relativePath = "a/fail.HEIC"; fail.status = "FAIL"
            let done = ManifestStore.donePaths(of: [ok, pulled, fail])
            try require(done.contains("a/ok.HEIC") && done.contains("a/pulled.HEIC"),
                        "OK/PULLED 都应计入 donePaths，得到 \(done)")
            try require(!done.contains("a/fail.HEIC"), "FAIL 不应计入 donePaths")
        }

        return outcomes
    }
}
