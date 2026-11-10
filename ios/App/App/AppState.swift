import SwiftUI
import Photos
import UIKit

struct ManifestStats {
    var okCount = 0
    var failCount = 0
    var bytes: Int64 = 0
    var malformed = 0

    static let empty = ManifestStats()
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

    @Published var exportRunning = false
    @Published var progress = ExportProgress.empty
    @Published var lastFinished: ExportSummary?
    @Published var selectedTab = 0

    @Published var manifestStats = ManifestStats.empty
    @Published var manifestRows: [ManifestRow] = []
    @Published var verifying = false
    @Published var verifyResult = VerifyResult()

    private var exportEngine: ExportEngine?
    private var autoTestScheduled = false

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        guard !estimating else { return }
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
        lastFinished = nil
        verifyResult = VerifyResult()
        UIApplication.shared.isIdleTimerDisabled = true // 屏幕常亮，保证前台稳定跑完
        print("PE EXPORT: start")
        let engine = ExportEngine(documentsURL: documentsURL)
        exportEngine = engine
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
            UIApplication.shared.isIdleTimerDisabled = false
            self.lastFinished = summary
            self.progress.currentFile = ""
            print("PE EXPORT: finish ok=\(summary.ok) failed=\(summary.failed) skipped=\(summary.skipped) cancelled=\(summary.cancelled)")
            self.loadManifest()
            self.refreshEstimate()
        }
        DispatchQueue.global(qos: .userInitiated).async { engine.run() }
    }

    func cancelExport() {
        exportEngine?.cancel()
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
