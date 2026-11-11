import SwiftUI
import Photos
import UIKit

struct ManifestStats {
    var okCount = 0
    var pulledCount = 0
    var failCount = 0
    var bytes: Int64 = 0
    var malformed = 0

    static let empty = ManifestStats()
}

/// 「清理已拉取文件」的结果。
struct CleanResult {
    var cleaned = 0
    var bytes: Int64 = 0
    var absent = 0   // 文件已不在手机（此前清理过/手动删过）
    var failed = 0   // 删除失败，保持 OK 下次再试
}

/// 校验结果（设备侧对已导出文件重算哈希）。
struct VerifyResult {
    var checked = 0
    var missing: [String] = []
    var mismatch: [String] = []
    var finished = false

    var allGood: Bool { finished && missing.isEmpty && mismatch.isEmpty }
}

/// 中心状态。约定：所有 @Published 只在主线程写（引擎回调已由引擎跳主队列，
/// 其余地方用 DispatchQueue.main.async）。
final class AppState: ObservableObject {

    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var libraryCount = 0
    @Published var estimatedBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published var estimating = false

    /// 分批导出：每批字节数上限（MB），0 = 不限。大库必备：装不下整个相册时按批导出→拉取→清理。
    /// 500 MB 档给剩余空间很小的手机（如 256G 只剩几个 G）。
    @Published var batchMB = 2048
    var batchBytesLimit: Int64 { Int64(batchMB) * 1_048_576 }

    @Published var exportRunning = false
    @Published var planningScanned = 0
    @Published var planningTotal = 0
    @Published var progress = ExportProgress.empty
    @Published var lastFinished: ExportSummary?
    @Published var selectedTab = 0

    @Published var cleaning = false
    @Published var cleanResult: CleanResult?

    @Published var manifestStats = ManifestStats.empty
    @Published var manifestRows: [ManifestRow] = []
    @Published var verifying = false
    @Published var verifyResult = VerifyResult()

    private var exportEngine: ExportEngine?
    private var keepAwakeTimer: Timer?
    private var autoTestScheduled = false

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// CI 构建号（Info.plist PEBuild，workflow 注入）；本地开发显示 dev。
    var buildLabel: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "PEBuild") as? String ?? ""
        return build.isEmpty ? "dev" : "#\(build)"
    }

    var manifestURL: URL {
        documentsURL.appendingPathComponent("manifest.csv")
    }

    init() {
        bootstrap()
    }

    private func bootstrap() {
        setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：console 重定向到文件时也能逐行看到输出
        print("PE BOOT: args=\(ProcessInfo.processInfo.arguments) debug=\(_isDebugAssertConfiguration())")
        ExportLog.write("BOOT build=\(buildLabel) args=\(ProcessInfo.processInfo.arguments.joined(separator: " "))")
        loadManifest()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-autoTest") {
            scheduleAutoTest()
        } else if args.contains("-autoSmoke") {
            SmokeTour.shared.begin(state: self)
        } else {
            refreshLibrary()
        }
        #else
        refreshLibrary()
        #endif
    }

    // MARK: - 相册状态

    func refreshLibrary() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let status = await PhotoLibraryService.requestAccess()
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = status
                guard status == .authorized || status == .limited else { return }
                self.libraryCount = PhotoLibraryService.fetchAllAssets().count
                self.refreshEstimate()
            }
        }
    }

    private func refreshEstimate() {
        // 全库容量预估要逐资产扫资源。两个约束：
        // 1) 大库要扫好几分钟，只估一次
        // 2) 大库干脆不扫：与导出规划的 PhotoKit 扫描并发会竞态（真机 32487 张上
        //    规划阶段 EXC_BREAKPOINT 的头号嫌疑），分批模式下引擎逐批报大小，预估没用
        guard !estimating, estimatedBytes == 0 else { return }
        guard libraryCount > 0, libraryCount <= 2000 else { return }
        estimating = true
        Task.detached(priority: .utility) { [weak self] in
            let bytes = PhotoLibraryService.estimatedLibraryBytes()
            let free = (try? URL(fileURLWithPath: NSTemporaryDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.estimatedBytes = bytes
                self.freeBytes = free
                self.estimating = false
            }
        }
    }

    var spaceWarning: String? {
        guard estimatedBytes > 0 else { return nil }
        if freeBytes > 0 && freeBytes < estimatedBytes {
            return "可用空间不足：约需 " + bytesString(estimatedBytes) + "，剩 " + bytesString(freeBytes)
        }
        return nil
    }

    // MARK: - 导出

    func startExport() {
        guard !exportRunning, authorization == .authorized || authorization == .limited else { return }
        exportRunning = true
        progress = .empty
        planningScanned = 0
        planningTotal = 0
        lastFinished = nil
        verifyResult = VerifyResult()
        setKeepAwake(true) // 屏幕常亮，保证前台稳定跑完
        print("PE EXPORT: start batchLimit=\(batchMB == 0 ? "unlimited" : "\(batchMB)MB")")
        ExportLog.write("EXPORT start build=\(buildLabel) batchMB=\(batchMB) library=\(libraryCount) free=\(bytesString(freeBytes))")
        let engine = ExportEngine(documentsURL: documentsURL, batchBytesLimit: batchBytesLimit)
        exportEngine = engine
        engine.onPlanning = { [weak self] scanned, total in
            guard let self else { return }
            self.planningScanned = scanned
            self.planningTotal = total
        }
        engine.onStart = { [weak self] total, bytes in
            guard let self else { return }
            self.progress.totalFiles = total
            self.progress.bytesTotal = bytes
        }
        engine.onFileStarted = { [weak self] path in
            guard let self else { return }
            self.progress.currentFile = (path as NSString).lastPathComponent
        }
        engine.onFileDone = { [weak self] _, snapshot in
            guard let self else { return }
            self.progress = snapshot
        }
        engine.onFinish = { [weak self] summary in
            guard let self else { return }
            self.exportRunning = false
            self.exportEngine = nil
            self.setKeepAwake(false)
            self.lastFinished = summary
            self.progress.currentFile = ""
            print("PE EXPORT: finish ok=\(summary.ok) failed=\(summary.failed) skipped=\(summary.skipped) cancelled=\(summary.cancelled)")
            ExportLog.write("EXPORT finish ok=\(summary.ok) failed=\(summary.failed) skipped=\(summary.skipped)"
                            + " cancelled=\(summary.cancelled) batchLimited=\(summary.batchLimited)"
                            + " stopped=\(summary.stoppedReason ?? "-")")
            self.loadManifest()
            self.refreshFreeSpace() // 预估只算一次，这里只刷新剩余空间
        }
        DispatchQueue.global(qos: .userInitiated).async { engine.run() }
    }

    func cancelExport() {
        exportEngine?.cancel()
    }

    /// 屏幕常亮。isIdleTimerDisabled 只设一次不可靠——用户真机（iOS 27）实锤导出中
    /// 依旧自动锁屏（低电量/系统紧绷等状态系统可能无视该标志）。导出期间由主线程
    /// Timer 每 20s 重申一次；readback 落日志，若「设了 true 却读到 false」就是实锤。
    private func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        if on {
            let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                guard let self, self.exportRunning else { return }
                UIApplication.shared.isIdleTimerDisabled = true
            }
            RunLoop.main.add(timer, forMode: .common)
            keepAwakeTimer = timer
        }
        ExportLog.write("KEEP-AWAKE \(on ? "on" : "off") readback=\(UIApplication.shared.isIdleTimerDisabled)")
    }

    /// 解锁回到前台时立即补一次常亮（上面的 Timer 最多 20s 后也会补，这里即时）
    func reassertKeepAwakeIfNeeded() {
        guard exportRunning else { return }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - 清理已拉取

    /// 大库分批工作流的关键一步：确认电脑端已拉取并校验 PASS 后，
    /// 删掉手机端已导出文件腾空间；清单改记 PULLED（哈希保留，证明链不断）。
    func cleanExportedFiles() {
        guard !exportRunning, !cleaning else { return }
        cleaning = true
        let root = documentsURL
        let manifestURL = self.manifestURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (rows, _) = ManifestStore.load(url: manifestURL)
            let dict = ManifestStore.rowDictionary(of: rows)
            let cleanable = dict.values.filter { $0.status == "OK" }
            var result = CleanResult()
            var pulledRows: [ManifestRow] = []
            let fm = FileManager.default
            for row in cleanable {
                let url = root.appendingPathComponent(row.relativePath)
                if fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        result.cleaned += 1
                        result.bytes += row.size
                    } catch {
                        result.failed += 1 // 删不掉的保持 OK，下次再试
                        continue
                    }
                } else {
                    result.absent += 1
                }
                var pulled = row
                pulled.status = "PULLED"
                pulled.note = "已拉取到电脑，手机端已清理"
                pulled.exportedAt = ManifestStore.now()
                pulledRows.append(pulled)
            }
            if !pulledRows.isEmpty {
                do { try ManifestStore.append(url: manifestURL, rows: pulledRows) } catch { /* 下次重试 */ }
            }
            print("PE CLEAN: cleaned=\(result.cleaned) absent=\(result.absent) failed=\(result.failed) freed=\(result.bytes)")
            ExportLog.write("CLEAN cleaned=\(result.cleaned) absent=\(result.absent) failed=\(result.failed) freed=\(result.bytes)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleaning = false
                self.cleanResult = result
                self.loadManifest()
                self.refreshFreeSpace()
            }
        }
    }

    func refreshFreeSpace() {
        Task.detached(priority: .utility) { [weak self] in
            let free = (try? URL(fileURLWithPath: NSTemporaryDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            DispatchQueue.main.async {
                self?.freeBytes = free
            }
        }
    }

    // MARK: - 清单

    func loadManifest() {
        let (rows, malformed) = ManifestStore.load(url: manifestURL)
        let dict = ManifestStore.rowDictionary(of: rows)
        var stats = ManifestStats()
        stats.malformed = malformed
        for row in dict.values {
            if row.status == "OK" {
                stats.okCount += 1
                stats.bytes += row.size
            } else if row.status == "PULLED" {
                stats.pulledCount += 1
            } else {
                stats.failCount += 1
            }
        }
        manifestStats = stats
        manifestRows = Array(rows.suffix(300).reversed())
    }

    /// 设备侧复核：对清单里所有 OK 的文件重算哈希（与 PC 端校验互为印证）。
    func verifyExported() {
        guard !verifying, !exportRunning else { return }
        verifying = true
        verifyResult = VerifyResult()
        let root = documentsURL
        let manifestURL = self.manifestURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (rows, _) = ManifestStore.load(url: manifestURL)
            let dict = ManifestStore.rowDictionary(of: rows)
            var result = VerifyResult()
            for (path, row) in dict where row.status == "OK" {
                let url = root.appendingPathComponent(path)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      (attrs[.size] as? Int64) == row.size,
                      let hash = try? FileHasher.sha256(of: url) else {
                    result.missing.append(path)
                    continue
                }
                if hash == row.sha256 {
                    result.checked += 1
                } else {
                    result.mismatch.append(path)
                }
            }
            result.finished = true
            DispatchQueue.main.async {
                guard let self else { return }
                self.verifying = false
                self.verifyResult = result
                print("PE VERIFY: checked=\(result.checked) missing=\(result.missing.count) mismatch=\(result.mismatch.count)")
                ExportLog.write("VERIFY checked=\(result.checked) missing=\(result.missing.count) mismatch=\(result.mismatch.count)")
            }
        }
    }

    // MARK: - 测试钩子（仅 DEBUG）

    #if DEBUG
    private func scheduleAutoTest() {
        guard !autoTestScheduled else { return }
        autoTestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            var failed = 0
            for outcome in TestSupport.runSelfTests() {
                lines.append((outcome.passed ? "PASS " : "FAIL ") + outcome.name
                             + (outcome.passed ? "" : " —— " + outcome.detail))
                if !outcome.passed { failed += 1 }
            }
            lines.append(failed == 0 ? "RESULT: ALL PASS" : "RESULT: \(failed) FAILURES")
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("autotest")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n")
                .write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            try? (failed == 0 ? "PASS" : "FAIL")
                .write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            exit(failed == 0 ? 0 : 1)
        }
    }
    #endif
}

/// 字节数展示（KB/MB/GB，一位小数）。
func bytesString(_ value: Int64) -> String {
    let value = Double(value)
    if value >= 1_073_741_824 { return String(format: "%.1f GB", value / 1_073_741_824) }
    if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
    if value >= 1024 { return String(format: "%.1f KB", value / 1024) }
    return "\(value) B"
}
