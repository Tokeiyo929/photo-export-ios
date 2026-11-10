import Foundation
import Photos

/// 导出进度快照（UI 用）。
struct ExportProgress {
    var totalFiles = 0
    var bytesTotal: Int64 = 0
    var doneFiles = 0
    var failedFiles = 0
    var skippedFiles = 0
    var bytesDone: Int64 = 0
    var currentFile = ""

    static let empty = ExportProgress()
}

/// 一次导出的总结。
struct ExportSummary {
    var totalFiles = 0
    var ok = 0
    var failed = 0
    var skipped = 0
    var bytesTotal: Int64 = 0
    var cancelled = false
    var errors: [String] = []
    /// 本批按字节上限收尾（剩下的下次「再次导出」继续）
    var batchLimited = false
    /// 空间护栏触发等原因导致提前结束的说明（非错误，UI 提示先拉取清理）
    var stoppedReason: String?

    var allGood: Bool { failed == 0 }
}

/// 导出引擎：规划 → 逐文件 tmp 写入 → SHA-256 → 移入 Documents 按日期目录 → 复算 SHA-256
/// → 一致才记 OK，否则记 FAIL 并删除坏文件。单文件失败只记清单，不中断整体。
/// manifest.csv 逐文件追加落盘：任意时刻被杀，已 OK 的行已在盘上，下次续跑跳过。
/// 大库友好：规划流式扫描，达到本批字节上限即停（不再全库扫一遍）；扫描中可取消；
/// 剩余空间低于护栏时优雅结束本批，提示先拉取清理。
final class ExportEngine {

    private let documentsURL: URL
    private let calendar: Calendar
    /// 本批字节数上限（0 = 不限）。规划扫到预算即停。
    private let batchBytesLimit: Int64
    /// 空间护栏：剩余可用低于「本文件大小 + 预留」时结束本批。
    private let freeSpaceReserve: Int64 = 1_073_741_824 // 1 GB
    private let lock = NSLock()
    private var cancelledFlag = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    // 回调一律在主队列
    var onStart: ((Int, Int64) -> Void)?
    /// 规划扫描进度（已扫描资产数, 相册总数），扫描期间 UI 显示"扫描 x/y"
    var onPlanning: ((Int, Int) -> Void)?
    var onFileStarted: ((String) -> Void)?
    var onFileDone: ((ManifestRow, ExportProgress) -> Void)?
    var onFinish: ((ExportSummary) -> Void)?

    private var progress = ExportProgress.empty

    init(documentsURL: URL, calendar: Calendar = .current, batchBytesLimit: Int64 = 0) {
        self.documentsURL = documentsURL
        self.calendar = calendar
        self.batchBytesLimit = batchBytesLimit
    }

    private struct WorkItem {
        let asset: PHAsset
        let resource: PHAssetResource
        let planned: PlannedFile
    }

    func run() {
        var summary = ExportSummary()
        let manifestURL = documentsURL.appendingPathComponent("manifest.csv")
        do {
            let (rows, _) = ManifestStore.load(url: manifestURL)
            let dict = ManifestStore.rowDictionary(of: rows)
            var doneSet = Set<String>()
            // assetId -> (photo/video -> [已完成的相对路径，按追加顺序])
            // 用于规划时按序消费，保证跨批重名消歧结果一致（不重导、不顶名）
            var doneByAsset: [String: [String: [String]]] = [:]
            for row in dict.values where row.status == "OK" || row.status == "PULLED" {
                doneSet.insert(row.relativePath)
                let kind = row.mediaType == "video" ? "video" : "photo"
                doneByAsset[row.assetId, default: [:]][kind, default: []].append(row.relativePath)
            }
            // 已占用的名字（OK/PULLED 的最终路径）参与重名去重
            var used = Set(doneSet.map { $0.lowercased() })
            var items: [WorkItem] = []
            let truncated = try planBatch(into: &items, doneByAsset: doneByAsset, used: &used)
            summary.batchLimited = truncated

            progress = ExportProgress()
            progress.totalFiles = items.count
            progress.bytesTotal = items.reduce(0) { $0 + $1.planned.fileSize }
            summary.totalFiles = items.count
            summary.bytesTotal = progress.bytesTotal
            main { self.onStart?(items.count, self.progress.bytesTotal) }

            for item in items {
                if cancelled {
                    summary.cancelled = true
                    break
                }
                // 空间护栏：写不下这个文件就停批，避免刷一屏"磁盘满"FAIL
                if let free = freeSpaceBytes(), free < item.planned.fileSize + freeSpaceReserve {
                    summary.stoppedReason = "剩余空间不足（剩 \(bytesString(free))，导 \(bytesString(item.planned.fileSize)) 需预留护栏）。本批到此为止：先把已导出文件拉到电脑并校验 PASS，再回 App 点「清理已拉取文件」释放空间后继续。"
                    break
                }
                let path = item.planned.relativePath
                if doneSet.contains(path) {
                    summary.skipped += 1
                    progress.skippedFiles += 1
                    progress.bytesDone += item.planned.fileSize
                    continue
                }
                main { self.onFileStarted?(path) }
                do {
                    let row = try exportOne(item: item, manifestURL: manifestURL)
                    if row.status == "OK" {
                        doneSet.insert(path)
                        summary.ok += 1
                        progress.doneFiles += 1
                    } else {
                        summary.failed += 1
                        summary.errors.append(path + " — " + row.note)
                        progress.failedFiles += 1
                    }
                    progress.bytesDone += row.size
                    main { self.onFileDone?(row, self.progress) }
                } catch {
                    var row = baseRow(item)
                    row.status = "FAIL"
                    row.note = String(error.localizedDescription.prefix(200))
                    do { try ManifestStore.append(url: manifestURL, rows: [row]) } catch { /* 磁盘满等：仍继续下一文件 */ }
                    summary.failed += 1
                    summary.errors.append(path + " — " + row.note)
                    progress.failedFiles += 1
                    main { self.onFileDone?(row, self.progress) }
                }
            }
        } catch is CancellationError {
            summary.cancelled = true
        } catch {
            summary.errors.append("规划失败 — " + error.localizedDescription)
        }
        main { self.onFinish?(summary) }
    }

    // MARK: - 单文件导出

    private func exportOne(item: WorkItem, manifestURL: URL) throws -> ManifestRow {
        let fileName = item.planned.fileName
        let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pe-export", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
        let tmpURL = tmpDirURL.appendingPathComponent(UUID().uuidString + "-" + fileName)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // 1) 从相册写原始字节（唯一允许的取原片 API）
        try PhotoLibraryService.writeOriginal(resource: item.resource, to: tmpURL)

        // 2) 写出后哈希（"复制前"）
        let writtenHash = try FileHasher.sha256(of: tmpURL)

        // 3) 移入正式目录（同路径旧文件是上次中断的半成品，直接替换）
        let destURL = documentsURL.appendingPathComponent(item.planned.relativePath)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destURL)

        // 4) 移动后哈希（"复制后"），一致才算成功
        let finalHash = try FileHasher.sha256(of: destURL)
        var row = baseRow(item)
        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        row.size = (attrs?[.size] as? Int64) ?? item.planned.fileSize
        if writtenHash == finalHash {
            row.status = "OK"
            row.sha256 = finalHash
        } else {
            row.status = "FAIL"
            row.note = "哈希不一致 tmp=\(String(writtenHash.prefix(12))) dest=\(String(finalHash.prefix(12)))"
            try? FileManager.default.removeItem(at: destURL) // 坏文件不留盘
        }
        try ManifestStore.append(url: manifestURL, rows: [row])
        return row
    }

    private func baseRow(_ item: WorkItem) -> ManifestRow {
        var row = ManifestRow()
        row.relativePath = item.planned.relativePath
        row.dateSource = item.planned.dateSource.rawValue
        row.assetId = item.asset.localIdentifier
        row.mediaType = item.asset.mediaType == .video ? "video" : "photo"
        row.favorite = item.asset.isFavorite
        row.exportedAt = ManifestStore.now()
        return row
    }

    // MARK: - 规划

    /// 流式规划本批工作项：按拍摄时间正序扫资产，扫到本批字节上限即停。
    /// 已完成的资源按 assetId+类型 从清单按序消费（名字已占用，不重导、不顶名）。
    /// 返回是否因预算截断。规划全程可取消、每 200 个回调一次进度。
    private func planBatch(into items: inout [WorkItem],
                           doneByAsset: [String: [String: [String]]],
                           used: inout Set<String>) throws -> Bool {
        let fetch = PhotoLibraryService.fetchAllAssets()
        let total = fetch.count
        var scanned = 0
        var batchBytes: Int64 = 0
        // 每资产的可变剩余完成表
        var remaining = doneByAsset
        for index in 0..<total {
            if cancelled { throw CancellationError() }
            let asset = fetch.object(at: index)
            scanned += 1
            if scanned % 200 == 0 || scanned == total {
                main { self.onPlanning?(scanned, total) }
            }
            let resources = PhotoLibraryService.exportResources(for: asset)
            guard !resources.isEmpty else { continue }
            let (directory, source) = ExportPlanner.dateDirectory(creationDate: asset.creationDate,
                                                                  fileDate: asset.modificationDate,
                                                                  calendar: calendar)
            for resource in resources {
                // 与清单行一致：mediaType 按 asset.mediaType 记（Live Photo 的 pairedVideo 行也是 "photo"），
                // 同一资产内按资源顺序消费，正好对应清单追加顺序
                let kind = asset.mediaType == .video ? "video" : "photo"
                // 已完成：按序消费对应清单行，跳过（其名字已在 used，不会被人顶掉）
                if var perKind = remaining[asset.localIdentifier],
                   var list = perKind[kind], !list.isEmpty {
                    list.removeFirst()
                    perKind[kind] = list
                    remaining[asset.localIdentifier] = perKind
                    continue
                }
                let fileName = ExportPlanner.disambiguate(fileName: resource.originalFilename,
                                                          directory: directory, used: &used)
                let size = PhotoLibraryService.fileSize(of: resource)
                items.append(WorkItem(asset: asset, resource: resource,
                                      planned: PlannedFile(relativePath: directory + "/" + fileName,
                                                           fileName: fileName,
                                                           directory: directory,
                                                           dateSource: source,
                                                           fileSize: size)))
                batchBytes += size
            }
            if batchBytesLimit > 0 && batchBytes >= batchBytesLimit {
                return true
            }
        }
        return false
    }

    /// 可用空间（按重要用途口径），取不到返回 nil（护栏跳过）。
    private func freeSpaceBytes() -> Int64? {
        try? documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func main(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}
