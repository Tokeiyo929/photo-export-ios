import Foundation
import Photos

/// 导出进度快照（UI 用）。running 阶段按**资产**计数（一个资产可能产出 1-2 个文件，
/// Live Photo 带实况视频）；bytesTotal 拷贝期才量得出（0 = 未知），bytesDone 按
/// 本批新写文件的实际大小累计。
struct ExportProgress {
    var totalFiles = 0        // 资产总数（running 期的分母）
    var bytesTotal: Int64 = 0 // 0 = 未知
    var doneFiles = 0         // 已完成资产数
    var failedFiles = 0       // 失败资产数
    var skippedFiles = 0      // 跳过资产数（已导过/无资源/已消失）
    var bytesDone: Int64 = 0
    var currentFile = ""

    static let empty = ExportProgress()
}

/// 一次导出的总结（按清单行 = 文件口径，与 manifest.csv 对应）。
struct ExportSummary {
    var totalFiles = 0        // 资产总数（与进度同口径）
    var ok = 0                // 本批写成功的文件行数
    var failed = 0
    var skipped = 0           // 消费掉的已完成文件行数（OK/PULLED）
    var bytesTotal: Int64 = 0 // 本批实际落盘字节（逐文件累计）
    var cancelled = false
    var errors: [String] = []
    /// 本批按字节上限收尾（剩下的下次「再次导出」继续）
    var batchLimited = false
    /// 空间护栏触发等原因导致提前结束的说明（非错误，UI 提示先拉取清理）
    var stoppedReason: String?

    var allGood: Bool { failed == 0 }
}

/// 导出引擎：规划（只摸元数据）→ 逐资产按 ID 现取资源 → 逐文件 tmp 写入 → SHA-256
/// → 移入 Documents 按日期目录 → 复算 SHA-256 → 一致才记 OK，否则记 FAIL 并删除坏文件。
/// 单文件失败只记清单，不中断整体；manifest.csv 逐文件追加落盘：任意时刻被杀，
/// 已 OK 的行已在盘上，下次续跑跳过。
/// 大库稳定性模式（参照成熟开源导出器 valtteriluomapareto/photo-export）：
/// - 规划段零 assetResources/fileSize 调用（逐资产 XPC 是大库热路径头号嫌疑）
/// - 资源解析/定名/量大小全部推迟到拷贝期，按 assetId 现取，不囤 PHAsset 对象
/// - 剩余空间护栏与字节预算都在拷贝期收口（写完一个文件检查一次）
final class ExportEngine {

    private let documentsURL: URL
    private let calendar: Calendar
    /// 本批字节数上限（0 = 不限）。拷贝期按实际落盘字节收口。
    private let batchBytesLimit: Int64
    /// 空间护栏：剩余可用低于「本文件大小 + 预留」时结束本批。
    private let freeSpaceReserve: Int64 = 1_073_741_824 // 1 GB
    private let lock = NSLock()
    private var cancelledFlag = false
    private let watchdog: StallWatchdog

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
    /// 每个资产处理完推进一次（按值快照，跨线程安全）
    var onProgress: ((ExportProgress) -> Void)?
    var onFinish: ((ExportSummary) -> Void)?

    private var progress = ExportProgress.empty

    init(documentsURL: URL, calendar: Calendar = .current, batchBytesLimit: Int64 = 0) {
        self.documentsURL = documentsURL
        self.calendar = calendar
        self.batchBytesLimit = batchBytesLimit
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pe-export", isDirectory: true)
        self.watchdog = StallWatchdog(blacklistURL: tmp.appendingPathComponent("plan-blacklist.txt"))
    }

    func run() {
        var summary = ExportSummary()
        let manifestURL = documentsURL.appendingPathComponent("manifest.csv")
        _ = watchdog.start()
        defer { watchdog.stop() } // 与 run 同寿；最多多活一个 20s 巡检周期
        do {
            sweepTmpLeftovers() // 上次崩溃可能遗留半成品 tmp，清掉（保留游标/黑名单）
            let (rows, _) = ManifestStore.load(url: manifestURL)
            let dict = ManifestStore.rowDictionary(of: rows)
            ExportLog.write("RUN start batchLimit=\(batchBytesLimit) manifestRows=\(dict.count) free=\(bytesString(freeSpaceBytes() ?? 0))")
            // assetId -> (photo/video -> [已完成的相对路径，按追加顺序])
            // 拷贝期按序消费，保证跨批重名消歧结果一致（不重导、不顶名）
            var remaining: [String: [String: [String]]] = [:]
            // 已占用的名字（OK/PULLED 的最终路径）参与重名去重
            var used = Set<String>()
            for row in dict.values where row.status == "OK" || row.status == "PULLED" {
                let kind = row.mediaType == "video" ? "video" : "photo"
                remaining[row.assetId, default: [:]][kind, default: []].append(row.relativePath)
                used.insert(row.relativePath.lowercased())
            }
            let assetIds = try planAssetIds()

            progress = ExportProgress()
            progress.totalFiles = assetIds.count
            summary.totalFiles = assetIds.count
            main { self.onStart?(assetIds.count, 0) }

            var batchBytesDone: Int64 = 0
            for (assetIndex, assetId) in assetIds.enumerated() {
                if cancelled { summary.cancelled = true; break }
                // 按 ID 现取资产（成熟导出器同款：拷贝期才解析，规划期不囤对象）
                watchdog.touch(phase: "copy", detail: "asset#\(assetIndex) call=refetch", assetId: assetId)
                guard let asset = autoreleasepool(invoking: { PhotoLibraryService.asset(withId: assetId) }) else {
                    ExportLog.write("ASSET-GONE index=\(assetIndex) id=\(assetId)")
                    progress.skippedFiles += 1
                    continue
                }
                watchdog.touch(phase: "copy", detail: "asset#\(assetIndex) call=assetResources", assetId: assetId)
                let resources = autoreleasepool { PhotoLibraryService.exportResources(for: asset) }
                if resources.isEmpty {
                    progress.skippedFiles += 1
                    continue
                }
                let (directory, source) = ExportPlanner.dateDirectory(creationDate: asset.creationDate,
                                                                      fileDate: asset.modificationDate,
                                                                      calendar: calendar)
                let kind = asset.mediaType == .video ? "video" : "photo"
                var writtenOK = 0
                var writtenFail = 0
                var consumed = 0
                var stopBatch = false
                for resource in resources {
                    // 已完成：按序消费对应清单行（名字已占用，不重导、不顶名）
                    if var perKind = remaining[assetId], var list = perKind[kind], !list.isEmpty {
                        list.removeFirst()
                        perKind[kind] = list
                        remaining[assetId] = perKind
                        consumed += 1
                        summary.skipped += 1
                        continue
                    }
                    // 预算收口：已写满本批上限 → 不再开新文件
                    if batchBytesLimit > 0 && batchBytesDone >= batchBytesLimit {
                        summary.batchLimited = true
                        stopBatch = true
                        break
                    }
                    let fileName = ExportPlanner.disambiguate(fileName: resource.originalFilename,
                                                              directory: directory, used: &used)
                    watchdog.touch(phase: "copy", detail: "asset#\(assetIndex) call=fileSize", assetId: assetId)
                    let size = autoreleasepool { PhotoLibraryService.fileSize(of: resource) }
                    // 空间护栏：写不下这个文件就停批，避免刷一屏"磁盘满"FAIL
                    if let free = freeSpaceBytes(), free < size + freeSpaceReserve {
                        summary.stoppedReason = "剩余空间不足（剩 \(bytesString(free))，导 \(bytesString(size)) 需预留护栏）。本批到此为止：先把已导出文件拉到电脑并校验 PASS，再回 App 点「清理已拉取文件」释放空间后继续。"
                        ExportLog.write("GUARD free=\(free) need=\(size + freeSpaceReserve) → 停批")
                        stopBatch = true
                        break
                    }
                    let path = directory + "/" + fileName
                    main { self.onFileStarted?(path) }
                    do {
                        // 崩溃豁免：同一文件连续 3 次都没能活着导完（上个进程死在它身上），
                        // 记 FAIL 跳过，别让一颗坏文件把整批无限卡死。
                        let previous = readCursor()
                        let starts = (previous.path == path) ? previous.starts + 1 : 1
                        if starts >= 3 {
                            ExportLog.write("FILE-SKIP \(path) starts=\(starts)")
                            var row = baseRow(asset: asset, relativePath: path, dateSource: source)
                            row.status = "FAIL"
                            row.note = "连续 \(starts) 次导出未完成（疑似该文件触发系统崩溃），本批已跳过"
                            try? ManifestStore.append(url: manifestURL, rows: [row])
                            summary.failed += 1
                            summary.errors.append(path + " — " + row.note)
                            writtenFail += 1
                            progress.bytesDone += size
                            continue
                        }
                        writeCursor(CrashCursor(path: path, starts: starts))
                        let row = try autoreleasepool {
                            try exportOne(asset: asset, resource: resource, relativePath: path,
                                          dateSource: source, manifestURL: manifestURL)
                        }
                        clearCursor() // 活着走完这个文件，解除怀疑
                        if row.status == "OK" {
                            summary.ok += 1
                            writtenOK += 1
                        } else {
                            summary.failed += 1
                            summary.errors.append(path + " — " + row.note)
                            writtenFail += 1
                        }
                        summary.bytesTotal += row.size
                        progress.bytesDone += row.size
                        batchBytesDone += row.size
                        if row.status == "OK" {
                            ExportLog.write("FILE OK \(path) size=\(row.size)")
                        } else {
                            ExportLog.write("FILE \(row.status) \(path) — \(row.note)")
                        }
                    } catch {
                        clearCursor() // exportOne 抛错但进程活着，也解除怀疑（FAIL 已记录，下轮重试）
                        ExportLog.write("FILE ERR \(path) diskFull=\(isDiskFull(error)) — \(String(error.localizedDescription.prefix(120)))")
                        var row = baseRow(asset: asset, relativePath: path, dateSource: source)
                        row.status = "FAIL"
                        row.note = String(error.localizedDescription.prefix(200))
                        do { try ManifestStore.append(url: manifestURL, rows: [row]) } catch { /* 磁盘满等：仍继续 */ }
                        summary.failed += 1
                        summary.errors.append(path + " — " + row.note)
                        writtenFail += 1
                        if isDiskFull(error) {
                            // 盘真的满了：继续只会刷 FAIL + 系统卡死，优雅收批
                            summary.stoppedReason = "磁盘写满，本批到此为止（不是错误）：先把已导出文件拉到电脑并校验 PASS，再回 App 点「清理已拉取文件」释放空间后继续。"
                            ExportLog.write("DISK-FULL 停批 free=\(bytesString(freeSpaceBytes() ?? 0))")
                            stopBatch = true
                            break
                        }
                    }
                }
                // 资产口径进度：动过的资产恰好落进一个桶；
                // 预算/护栏在本资产第一笔之前触发的不计（本批到此为止）
                if consumed > 0 || writtenOK > 0 || writtenFail > 0 {
                    if consumed > 0 && writtenOK == 0 && writtenFail == 0 {
                        progress.skippedFiles += 1
                    } else if writtenFail > 0 {
                        progress.failedFiles += 1
                    } else {
                        progress.doneFiles += 1
                    }
                }
                let snapshot = progress
                main { self.onProgress?(snapshot) }
                if stopBatch { break }
            }
        } catch is CancellationError {
            summary.cancelled = true
        } catch {
            summary.errors.append("规划失败 — " + error.localizedDescription)
        }
        clearCursor() // 本次是正常收尾（含取消/护栏/写满），崩溃怀疑清零
        clearPlanCursor()
        ExportLog.write("FINISH ok=\(summary.ok) failed=\(summary.failed) skipped=\(summary.skipped)"
                        + " cancelled=\(summary.cancelled) batchLimited=\(summary.batchLimited)"
                        + " stopped=\(summary.stoppedReason ?? "-") errors=\(summary.errors.count)")
        let finished = summary
        main { self.onFinish?(finished) }
    }

    // MARK: - 规划（只摸元数据）

    /// 流式规划本批要处理的资产 ID：每资产只读 localIdentifier 一个调用。
    /// 资源解析/定名/量大小全部推迟到拷贝期按 ID 现取——规划段不再逐资产调
    /// assetResources/fileSize（成熟导出器 #245 列定的大库热路径头号嫌疑，
    /// 真机 32k 库曾在此挂死 3.5 分钟）。扫描全程可取消，每 500 个回调一次进度。
    private func planAssetIds() throws -> [String] {
        let fetch = PhotoLibraryService.fetchAllAssets()
        let total = fetch.count
        var ids: [String] = []
        ids.reserveCapacity(total)
        // 规划段崩溃豁免：处理每个资产前写「该资产第几次尝试」；
        // 进程若死在扫描上，下轮同一资产第 3 次启动即跳过
        var planCursor = readPlanCursor()
        let blacklist = Set(watchdog.planBlacklist())
        for index in 0..<total {
            if cancelled { throw CancellationError() }
            watchdog.touch(phase: "plan", detail: "index=\(index)/\(total) call=fetchObject")
            let id = fetch.object(at: index).localIdentifier
            // 黑名单：上次规划在同一资产上卡死 ≥3 分钟的，直接跳过
            // （卡死的线程无法自救，只能靠重跑绕开）
            if blacklist.contains(id) {
                ExportLog.write("PLAN-BLACKLIST skip index=\(index) id=\(id)")
                continue
            }
            let starts = (planCursor.index == index && planCursor.assetId == id)
                ? planCursor.starts + 1 : 1
            if starts >= 3 {
                ExportLog.write("PLAN-SKIP index=\(index) id=\(id.prefix(24)) starts=\(starts)")
                planCursor = PlanCursor()
                clearPlanCursor()
                continue
            }
            planCursor = PlanCursor(index: index, assetId: id, starts: starts)
            writePlanCursor(planCursor)
            ids.append(id)
            if ids.count % 500 == 0 || ids.count == total {
                let seen = ids.count
                let all = total
                ExportLog.write("PLAN \(seen)/\(all)")
                main { self.onPlanning?(seen, all) }
            }
        }
        clearPlanCursor() // 规划正常收官，豁免计数清零
        return ids
    }

    // MARK: - 单文件导出

    private func exportOne(asset: PHAsset, resource: PHAssetResource, relativePath: String,
                           dateSource: DateSource, manifestURL: URL) throws -> ManifestRow {
        let tmpURL = tmpDirURL.appendingPathComponent(UUID().uuidString + "-"
                                                      + (relativePath as NSString).lastPathComponent)
        try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // 1) 从相册写原始字节（唯一允许的取原片 API；iCloud 原片在这里按需下载，慢属正常）
        watchdog.touch(phase: "copy", detail: "\(relativePath) call=writeData", assetId: asset.localIdentifier)
        try PhotoLibraryService.writeOriginal(resource: resource, to: tmpURL)

        // 2) 写出后哈希（"复制前"）
        watchdog.touch(phase: "copy", detail: "\(relativePath) call=hash", assetId: asset.localIdentifier)
        let writtenHash = try FileHasher.sha256(of: tmpURL)

        // 3) 移入正式目录（同路径旧文件是上次中断的半成品，直接替换）
        watchdog.touch(phase: "copy", detail: "\(relativePath) call=move", assetId: asset.localIdentifier)
        let destURL = documentsURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destURL)

        // 4) 移动后哈希（"复制后"），一致才算成功
        watchdog.touch(phase: "copy", detail: "\(relativePath) call=verify-hash", assetId: asset.localIdentifier)
        let finalHash = try FileHasher.sha256(of: destURL)
        var row = baseRow(asset: asset, relativePath: relativePath, dateSource: dateSource)
        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        row.size = (attrs?[.size] as? Int64) ?? 0
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

    private func baseRow(asset: PHAsset, relativePath: String, dateSource: DateSource) -> ManifestRow {
        var row = ManifestRow()
        row.relativePath = relativePath
        row.dateSource = dateSource.rawValue
        row.assetId = asset.localIdentifier
        row.mediaType = asset.mediaType == .video ? "video" : "photo"
        row.favorite = asset.isFavorite
        row.exportedAt = ManifestStore.now()
        return row
    }

    /// 可用空间：取「严格口径」与「重要用途口径」的较小值。
    /// 重要用途口径会把可清除缓存也算进可用，虚高——手机只剩几个 G 时按它放行，
    /// 真写到盘满系统会卡死然后杀掉 App（真机实测）；两个口径取小才诚实。取不到返回 nil（护栏跳过）。
    private func freeSpaceBytes() -> Int64? {
        guard let values = try? documentsURL.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }
        let strict = values.volumeAvailableCapacity
        let important = values.volumeAvailableCapacityForImportantUsage
        switch (strict, important) {
        case let (s?, i?): return min(Int64(s), i)
        case let (s?, nil): return Int64(s)
        case let (nil, i?): return i
        default: return nil
        }
    }

    /// 是否磁盘写满（ENOSPC）：Cocoa 640 / POSIX 28，含底层错误链。
    private func isDiskFull(_ error: Error) -> Bool {
        func full(_ ns: NSError) -> Bool {
            (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == 28)
        }
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        return full(ns) || (underlying.map(full) ?? false)
    }

    // MARK: - 崩溃游标

    /// 记录"正在导哪个文件、第几次尝试"。进程若死在某个文件上，游标留在盘上；
    /// 下次运行同一文件第三次启动即豁免跳过。正常走完一个文件就清游标。
    private struct CrashCursor {
        var path = ""
        var starts = 0
    }

    private var tmpDirURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pe-export", isDirectory: true)
    }

    private var cursorURL: URL {
        tmpDirURL.appendingPathComponent("cursor.txt")
    }

    private func readCursor() -> CrashCursor {
        guard let raw = try? String(contentsOf: cursorURL, encoding: .utf8) else { return CrashCursor() }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let starts = Int(lines[1]) else { return CrashCursor() }
        return CrashCursor(path: lines[0], starts: starts)
    }

    private func writeCursor(_ cursor: CrashCursor) {
        try? FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
        let text = cursor.path + "\n" + String(cursor.starts)
        try? text.data(using: .utf8)?.write(to: cursorURL, options: .atomic)
    }

    private func clearCursor() {
        try? FileManager.default.removeItem(at: cursorURL)
    }

    // MARK: - 规划段崩溃游标

    /// 与拷贝段游标同理，但按「资产下标 + localIdentifier」记。
    private struct PlanCursor {
        var index = -1
        var assetId = ""
        var starts = 0
    }

    private var planCursorURL: URL {
        tmpDirURL.appendingPathComponent("plan-cursor.txt")
    }

    private func readPlanCursor() -> PlanCursor {
        guard let raw = try? String(contentsOf: planCursorURL, encoding: .utf8) else { return PlanCursor() }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, let index = Int(lines[0]), let starts = Int(lines[2]) else { return PlanCursor() }
        return PlanCursor(index: index, assetId: lines[1], starts: starts)
    }

    private func writePlanCursor(_ cursor: PlanCursor) {
        try? FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
        let text = "\(cursor.index)\n\(cursor.assetId)\n\(cursor.starts)"
        try? text.data(using: .utf8)?.write(to: planCursorURL, options: .atomic)
    }

    private func clearPlanCursor() {
        try? FileManager.default.removeItem(at: planCursorURL)
    }

    /// 清掉上次崩溃遗留的半成品 tmp（导出中的 UUID-文件名），游标与黑名单保留。
    private func sweepTmpLeftovers() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: tmpDirURL,
                                                                     includingPropertiesForKeys: nil)) ?? []
        let keep: Set<String> = ["cursor.txt", "plan-cursor.txt", "plan-blacklist.txt"]
        for item in contents where !keep.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func main(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}

/// 心跳看门狗：真机大库的「闪退」常常不留崩溃报告（卡死后被系统静默杀掉），
/// 日志最后一行没了下文，定位不到卡在哪个调用。引擎在每个 PhotoKit 调用前
/// touch 一次心跳；看门狗协程每 20s 巡检，同一调用点停住 60s 起每分钟落一行
/// STALL（阶段/调用点/卡了多久）。规划段卡死 ≥3 分钟判定为坏资产：写进
/// plan-blacklist.txt，下次运行直接跳过——卡死的线程无法自救，只能重跑绕开。
/// 拷贝段不拉黑：writeData 对 iCloud 原片按需下载，慢是正常的，只记日志。
private final class StallWatchdog {

    private let lock = NSLock()
    private let blacklistURL: URL
    private var phase = ""
    private var detail = ""
    private var assetId = ""
    private var lastTouch = Date()
    private var lastLoggedMinute = 0
    private var stopped = false

    init(blacklistURL: URL) {
        self.blacklistURL = blacklistURL
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// 阶段推进时调用；detail 不变（还停在同一调用里）则保持原时间戳
    func touch(phase: String, detail: String, assetId: String = "") {
        lock.lock(); defer { lock.unlock() }
        if self.phase != phase || self.detail != detail {
            self.phase = phase
            self.detail = detail
            self.assetId = assetId
            self.lastTouch = Date()
            self.lastLoggedMinute = 0
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func start() -> Task<Void, Never> {
        let watchdog = self
        return Task.detached(priority: .utility) {
            while !watchdog.isStopped {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let line = watchdog.poll() { ExportLog.write(line) }
            }
        }
    }

    /// 停住 ≥60s 时返回日志行（每分钟一行），否则 nil。
    /// 规划段满 3 分钟即把当前资产拉黑（一次误判的代价只是少导一张，可重跑补回）。
    func poll() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !phase.isEmpty else { return nil }
        let age = Date().timeIntervalSince(lastTouch)
        guard age >= 60 else { return nil }
        let minute = Int(age / 60)
        guard minute > lastLoggedMinute else { return nil }
        lastLoggedMinute = minute
        if phase == "plan", !assetId.isEmpty, minute >= 3 {
            appendBlacklist(assetId)
            return "STALL-FATAL phase=plan stuck=\(Int(age))s asset=\(assetId) 已入黑名单，取消后重跑将跳过该资产"
        }
        return "STALL phase=\(phase) stuck=\(Int(age))s at \(detail)"
    }

    private func appendBlacklist(_ assetId: String) {
        var lines = planBlacklist()
        guard !lines.contains(assetId) else { return }
        lines.append(assetId)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: blacklistURL, options: .atomic)
    }

    func planBlacklist() -> [String] {
        guard let raw = try? String(contentsOf: blacklistURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
