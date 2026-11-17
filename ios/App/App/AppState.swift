import SwiftUI
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

/// 中心状态。约定：所有 @Published 只在主线程写（其余地方用 DispatchQueue.main.async）。
/// 产品收缩（2026-11）：全量导出引擎与 PHPicker 补漏下线，只保留分享导入这一条入口。
final class AppState: ObservableObject {

    @Published var selectedTab = 0

    @Published var cleaning = false
    @Published var cleanResult: CleanResult?

    @Published var manifestStats = ManifestStats.empty
    @Published var manifestRows: [ManifestRow] = []
    @Published var verifying = false
    @Published var verifyResult = VerifyResult()

    private var wifiServer: WifiServer?
    private var autoTestScheduled = false

    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    @Published var wifiRunning = false
    @Published var wifiURLs: [String] = []
    /// 首页「分享导入」卡片状态：收件箱待登记数 / 共享容器是否可用 / 探测详情 / 上次结果
    @Published var sharePending = 0
    @Published var shareContainerOK = true
    @Published var shareProbe = ""
    @Published var shareLastLine = ""
    @Published var shareExtLine = ""
    /// 一次截图定位 0 项原因：主 App 落到的组名 + 队列/收件箱/导入摘要
    @Published var shareGroup = ""
    @Published var shareDiag = ""

    /// 相册「分享→无损导出」的收件箱落位：搬进 Documents + 登记清单。
    func drainSharedInbox() {
        let documents = documentsURL
        let manifest = manifestURL
        shareLastLine = "正在登记…" // 点按钮立即有反馈，别让人以为没反应
        Task.detached(priority: .utility) { [weak self] in
            // 两条通道都收：App Group 收件箱（分享扩展）+ Documents/Inbox（分享面板直投，
            // 免费 Sideloadly 不给组权限时唯一能走通的路）
            let ext = SharedIn.drain(documentsURL: documents, manifestURL: manifest)
            let openIn = SharedIn.drainOpenInInbox(documentsURL: documents, manifestURL: manifest)
            let imported = ext.imported + openIn.imported
            let skipped = ext.skipped + openIn.skipped
            let failed = ext.failed + openIn.failed
            // 卡片状态每次都刷（哪怕 0 条）：用户分享完回首页要有反馈，不能一片空白
            let ok = SharedGroup.container() != nil
            let pending = SharedGroup.pendingCount()
            let probe = SharedGroup.lastProbeDescription
            let group = SharedGroup.resolvedGroupName
            let diag = SharedIn.lastDiagnostics
            let stamp = Self.iso.string(from: Date())
            ExportLog.write("SHARE drain imported=\(imported) skipped=\(skipped) failed=\(failed) pending=\(pending) containerOK=\(ok) probe=\(probe) diag=\(diag)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.shareContainerOK = ok
                self.sharePending = pending
                self.shareProbe = probe
                self.shareGroup = group
                self.shareDiag = diag
                self.shareExtLine = (try? String(contentsOf: documents.appendingPathComponent("share-ext-last.txt"),
                                                 encoding: .utf8)) ?? ""
                if imported > 0 {
                    // 重复分享的旧照片会按 内容哈希+文件名 自动跳过——必须写明数量，
                    // 否则「只登记 9 个」会被理解成丢了 91 个
                    self.shareLastLine = "\(stamp) 已登记 \(imported) 项"
                        + (skipped > 0 ? "；另有 \(skipped) 项之前已登记过（重复分享自动跳过）" : "")
                        + (failed > 0 ? "；\(failed) 项失败（见下方诊断）" : "")
                    self.loadManifest()
                    try? Data(self.shareLastLine.utf8)
                        .write(to: documents.appendingPathComponent("share-last.txt"))
                } else if failed > 0 {
                    self.shareLastLine = "\(stamp) \(failed) 项登记失败（首个错误见下方诊断）"
                } else if skipped > 0 {
                    self.shareLastLine = "\(stamp) 没有新文件：\(skipped) 项之前已登记过（同一张照片重复分享不会重复入库）"
                } else {
                    self.shareLastLine = "\(stamp) 没有收到新文件"
                }
            }
        }
    }

    /// 分享面板直投：系统递来的文件 URL（LSSupportsOpeningDocumentsInPlace=true 时是
    /// 原件 URL，需要 security-scope；系统拷到 Inbox 时则交给 drainSharedInbox 统一扫）。
    func receiveOpenIn(_ url: URL) {
        // photoexport://shared = 分享扩展登记完尽力拉起主 App 的信号（扩展侧 open 可能被系统拒），
        // 不是文件，扫一遍收件箱即可
        guard url.isFileURL else {
            drainSharedInbox()
            return
        }
        let documents = documentsURL
        if url.path.hasPrefix(documents.appendingPathComponent("Inbox").path + "/") {
            drainSharedInbox()
            return
        }
        let manifest = manifestURL
        Task.detached(priority: .utility) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // in-place 原件（Files/iCloud 地址）先拷进 Inbox 再走同一条链——importFile 会 move，
            // 直接 move 会把用户原目录里的文件搬走
            var source = url
            if scoped {
                let staged = documents.appendingPathComponent("Inbox", isDirectory: true)
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staged)
                    try FileManager.default.copyItem(at: url, to: staged)
                    source = staged
                } catch {
                    ExportLog.write("OPENIN stage FAIL \(url.lastPathComponent): \(error)")
                    return
                }
            }
            let sets = SharedIn.guardSets(documentsURL: documents, manifestURL: manifest)
            var known = sets.known
            var used = sets.used
            do {
                if let row = try SharedIn.importFile(source, documentsURL: documents, inboxFile: url.lastPathComponent,
                                                     known: &known, used: &used, note: "",
                                                     iso: ISO8601DateFormatter(), fallbackNote: "分享直投") {
                    try? ManifestStore.append(url: manifest, rows: [row])
                    ExportLog.write("OPENIN url ok=\(url.lastPathComponent)")
                    DispatchQueue.main.async { self?.loadManifest() }
                } else {
                    ExportLog.write("OPENIN url skip=dup \(url.lastPathComponent)")
                }
            } catch {
                ExportLog.write("OPENIN url FAIL \(url.lastPathComponent): \(error)")
            }
        }
    }

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
        // 上次分享导入结果（跨重启可见）：分享扩展写完回首页没反馈的投诉就靠它兜住
        shareLastLine = (try? String(contentsOf: documentsURL.appendingPathComponent("share-last.txt"),
                                     encoding: .utf8)) ?? ""
        shareExtLine = (try? String(contentsOf: documentsURL.appendingPathComponent("share-ext-last.txt"),
                                    encoding: .utf8)) ?? ""
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-autoTest") {
            scheduleAutoTest()
        } else if args.contains("-autoSmoke") {
            SmokeTour.shared.begin(state: self)
        }
        #endif
        // 顺路探测一次 App Group：组解析详情随日志落地（排查分享链路的常驻证据源）
        _ = SharedGroup.container()
        ExportLog.write("GROUP \(SharedGroup.lastProbeDescription)")
    }

    // MARK: - WiFi 直传

    /// 局域网 HTTP 直传：iOS 27 的数据线 AFC 通道对本 App 服务了错误的容器视图
    /// （按名读永远 OBJECT_NOT_FOUND），WiFi 是可用的拉取通道（LocalSend 同款模式）。
    func startWifiServer() {
        guard !wifiRunning else { return }
        let server = WifiServer(documentsURL: documentsURL, port: 8765)
        server.start()
        wifiServer = server
        wifiRunning = true
        wifiURLs = server.localURLs
        ExportLog.write("WIFI start urls=\(server.localURLs.joined(separator: " "))")
    }

    func stopWifiServer() {
        wifiServer?.stop()
        wifiServer = nil
        wifiRunning = false
        wifiURLs = []
    }

    // MARK: - 清理已拉取

    /// 大库分批工作流的关键一步：确认电脑端已拉取并校验 PASS 后，
    /// 删掉手机端已导出文件腾空间；清单改记 PULLED（哈希保留，证明链不断）。
    func cleanExportedFiles() {
        guard !cleaning else { return }
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
        guard !verifying else { return }
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
            let outcomes = TestSupport.runSelfTests() + SharePipelineTest.run()
            for outcome in outcomes {
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
