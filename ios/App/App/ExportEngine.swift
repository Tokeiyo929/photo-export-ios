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

    var allGood: Bool { failed == 0 }
}

/// 导出引擎：规划 → 逐文件 tmp 写入 → SHA-256 → 移入 Documents 按日期目录 → 复算 SHA-256
/// → 一致才记 OK，否则记 FAIL 并删除坏文件。单文件失败只记清单，不中断整体。
/// manifest.csv 逐文件追加落盘：任意时刻被杀，已 OK 的行已在盘上，下次续跑跳过。
final class ExportEngine {

    private let documentsURL: URL
    private let calendar: Calendar
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
    var onFileStarted: ((String) -> Void)?
    var onFileDone: ((ManifestRow, ExportProgress) -> Void)?
    var onFinish: ((ExportSummary) -> Void)?

    private var progress = ExportProgress.empty

    init(documentsURL: URL, calendar: Calendar = .current) {
        self.documentsURL = documentsURL
        self.calendar = calendar
    }

    private struct WorkItem {
        let asset: PHAsset
        let resource: PHAssetResource
        let planned: PlannedFile
    }

    func run() {
        var summary = ExportSummary()
        do {
            let items = try buildWorkItems()
            let manifestURL = documentsURL.appendingPathComponent("manifest.csv")
            let (rows, _) = ManifestStore.load(url: manifestURL)
            var okSet = ManifestStore.okPaths(of: rows)

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
                let path = item.planned.relativePath
                if okSet.contains(path) {
                    summary.skipped += 1
                    progress.skippedFiles += 1
                    progress.bytesDone += item.planned.fileSize
                    continue
                }
                main { self.onFileStarted?(path) }
                do {
                    let row = try exportOne(item: item, manifestURL: manifestURL)
                    if row.status == "OK" {
                        okSet.insert(path)
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

    private func buildWorkItems() throws -> [WorkItem] {
        let fetch = PhotoLibraryService.fetchAllAssets()
        var assets: [PHAsset] = []
        var assetsInfo: [AssetInfo] = []
        var flatResources: [PHAssetResource] = []
        fetch.enumerateObjects { asset, _, _ in
            let resources = PhotoLibraryService.exportResources(for: asset)
            guard !resources.isEmpty else { return }
            assets.append(asset)
            assetsInfo.append(AssetInfo(id: asset.localIdentifier,
                                        mediaType: asset.mediaType == .video ? "video" : "photo",
                                        isLive: asset.mediaSubtypes.contains(.photoLive),
                                        isFavorite: asset.isFavorite,
                                        creationDate: asset.creationDate,
                                        fileDate: asset.modificationDate,
                                        resources: resources.map { ResourceInfo(fileName: $0.originalFilename,
                                                                               size: PhotoLibraryService.fileSize(of: $0) }))
            flatResources.append(contentsOf: resources)
        }
        let planned = ExportPlanner.plan(assets: assetsInfo, calendar: calendar)
        guard planned.count == flatResources.count else {
            throw NSError(domain: "ExportEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "规划数 \(planned.count) 与资源数 \(flatResources.count) 不一致"])
        }
        var items: [WorkItem] = []
        items.reserveCapacity(planned.count)
        for (index, plan) in planned.enumerated() {
            items.append(WorkItem(asset: assets[index], resource: flatResources[index], planned: plan))
        }
        return items
    }

    private func main(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}
