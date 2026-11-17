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

/// 「清空手机端照片文件」的结果。
struct CleanResult {
    var cleaned = 0
    var bytes: Int64 = 0
    var absent = 0   // 清单里 OK 但文件本就不在（此前清理过/手动删过）
    var orphans = 0  // 清单外残留的照片文件（一并扫掉）
    var failed = 0   // 删除失败，保持 OK 下次再试
}

/// 中心状态。约定：所有 @Published 只在主线程写（其余地方用 DispatchQueue.main.async）。
/// 产品收缩（2026-11）：全量导出引擎与 PHPicker 补漏下线，只保留分享导入这一条入口。
final class AppState: ObservableObject {

    @Published var cleaning = false
    @Published var cleanResult: CleanResult?

    @Published var manifestStats = ManifestStats.empty

    private var autoTestScheduled = false

    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// 首页「分享导入」卡片状态：收件箱待登记数 / 共享容器是否可用 / 探测详情 / 上次结果
    @Published var sharePending = 0
    @Published var shareContainerOK = true
    @Published var shareProbe = ""
    @Published var shareLastLine = ""
    @Published var shareExtLine = ""
    /// 一次截图定位 0 项原因：主 App 落到的组名 + 队列/收件箱/导入摘要
    @Published var shareGroup = ""
    @Published var shareDiag = ""

    /// 「导入」文件夹（主通道）+ 分享扩展 + 直投 Inbox 的收件落位：搬进 App Support + 登记清单。
    func drainSharedInbox() {
        let documents = AppStorage.documentsURL
        let store = AppStorage.storeURL
        _ = AppStorage.importFolderURL // 顺手保证「导入」文件夹在文件 App 里可见
        let manifest = manifestURL
        shareLastLine = "正在登记…" // 点按钮立即有反馈，别让人以为没反应
        Task.detached(priority: .utility) { [weak self] in
            // 三条通道都收：①文件 App「导入」文件夹（相册→存储到文件，主通道）
            // ②App Group 收件箱（分享扩展）③Documents/Inbox（分享面板直投）
            let ext = SharedIn.drain(storeURL: store, manifestURL: manifest)
            let openIn = SharedIn.drainOpenInInbox(documentsURL: documents, storeURL: store, manifestURL: manifest)
            let folder = SharedIn.drainImportFolder(documentsURL: documents, storeURL: store, manifestURL: manifest)
            let imported = ext.imported + openIn.imported + folder.imported
            let skipped = ext.skipped + openIn.skipped + folder.skipped
            let failed = ext.failed + openIn.failed + folder.failed
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
                self.shareExtLine = (try? String(contentsOf: SharedIn.extLastURL(store), encoding: .utf8)) ?? ""
                self.refreshStorage()
                if imported > 0 {
                    // 重复分享的旧照片会按 内容哈希+文件名 自动跳过——必须写明数量，
                    // 否则「只登记 9 个」会被理解成丢了 91 个
                    self.shareLastLine = "\(stamp) 已登记 \(imported) 项"
                        + (skipped > 0 ? "；另有 \(skipped) 项之前已登记过（重复分享自动跳过）" : "")
                        + (failed > 0 ? "；\(failed) 项失败（见下方诊断）" : "")
                    self.loadManifest()
                    try? Data(self.shareLastLine.utf8)
                        .write(to: SharedIn.lastResultURL(store))
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
        let documents = AppStorage.documentsURL
        let store = AppStorage.storeURL
        if url.path.hasPrefix(documents.appendingPathComponent("Inbox").path + "/") {
            drainSharedInbox()
            return
        }
        if url.path.hasPrefix(documents.appendingPathComponent("导入").path + "/") {
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
            let sets = SharedIn.guardSets(storeURL: store, manifestURL: manifest)
            var known = sets.known
            var used = sets.used
            do {
                if let row = try SharedIn.importFile(source, storeURL: store, inboxFile: url.lastPathComponent,
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

    var documentsURL: URL { AppStorage.documentsURL }

    /// CI 构建号（Info.plist PEBuild，workflow 注入）；本地开发显示 dev。
    var buildLabel: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "PEBuild") as? String ?? ""
        return build.isEmpty ? "dev" : "#\(build)"
    }

    var manifestURL: URL { AppStorage.manifestURL }

    init() {
        bootstrap()
    }

    private func bootstrap() {
        setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：console 重定向到文件时也能逐行看到输出
        print("PE BOOT: args=\(ProcessInfo.processInfo.arguments) debug=\(_isDebugAssertConfiguration())")
        ExportLog.write("BOOT build=\(buildLabel) args=\(ProcessInfo.processInfo.arguments.joined(separator: " "))")
        // 迁移链（都幂等，按历史状态各取所需）：
        // ① v1 收编 Documents 根的散落年份目录/内部文件（manifest 还在 Documents 时就要做）
        collectYearDirs(root: AppStorage.documentsURL,
                        manifestURL: AppStorage.documentsURL.appendingPathComponent("manifest.csv"))
        // ② v3：manifest/photos/logs 整体搬进 Application Support（文件 App 不可见）
        AppStorage.migrateLegacyDocuments()
        // ③ store 里万一也有散落目录（半途迁移等），同样收编
        collectYearDirs(root: AppStorage.storeURL, manifestURL: manifestURL)
        // ④ 「导入」文件夹必须在文件 App 里一直可见（用户的主入口）
        _ = AppStorage.importFolderURL
        loadManifest()
        // 上次分享导入结果（跨重启可见）：分享扩展写完回首页没反馈的投诉就靠它兜住
        let store = AppStorage.storeURL
        let legacyRoot = { (name: String) in AppStorage.documentsURL.appendingPathComponent(name) }
        shareLastLine = (try? String(contentsOf: SharedIn.lastResultURL(store), encoding: .utf8))
            ?? (try? String(contentsOf: legacyRoot("share-last.txt"), encoding: .utf8)) ?? ""
        shareExtLine = (try? String(contentsOf: SharedIn.extLastURL(store), encoding: .utf8))
            ?? (try? String(contentsOf: legacyRoot("share-ext-last.txt"), encoding: .utf8)) ?? ""
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

    // MARK: - 目录布局（v3：内部文件住 App Support，Documents 只留「导入」文件夹）

    /// v1 收编（参数化，Documents 与 store 各跑一次）：老版本把照片年份目录和
    /// share-*/export-log* 散在根目录——年份目录整体挪进 photos/，内部文件挪进 logs/，
    /// 清单相对路径补 photos/ 前缀。根上没有散落目录时无事发生。
    private func collectYearDirs(root: URL, manifestURL: URL) {
        let fm = FileManager.default
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        if !fm.fileExists(atPath: photos.path) {
            try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        }
        var movedDirs: Set<String> = []
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in items {
                let name = url.lastPathComponent
                if name == "Inbox" || name == "photos" || name == "logs" || name == "导入" { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                // 照片归档目录（年份/UNDATED）整体挪进 photos/
                guard (try? fm.moveItem(at: url, to: photos.appendingPathComponent(name))) != nil else { continue }
                movedDirs.insert(name)
            }
        }
        moveAuxFilesToLogs(root: root)
        // 不以 photos/ 是否已存在为门槛：ipa-61 期间导入过裸路径文件的用户，
        // 根目录会重新长出 2025/ 这类目录——每次启动都要把它们收编进 photos/
        guard !movedDirs.isEmpty else { return }
        // 清单相对路径加 photos/ 前缀（只对真的搬动成功的目录）
        let (rows, malformed) = ManifestStore.load(url: manifestURL)
        var updated: [ManifestRow] = []
        var changed = false
        for var row in rows {
            let first = row.relativePath.split(separator: "/").first.map(String.init) ?? ""
            if movedDirs.contains(first), !row.relativePath.hasPrefix("photos/") {
                row.relativePath = "photos/" + row.relativePath
                changed = true
            }
            updated.append(row)
        }
        if changed {
            try? ManifestStore.writeAll(url: manifestURL, rows: updated)
        }
        ExportLog.write("MIGRATE layout root=\(root.lastPathComponent) dirs=[\(movedDirs.sorted().joined(separator: ","))] rows=\(updated.count) malformed=\(malformed) rewritten=\(changed)")
    }

    /// 根目录散落的内部文件（share-*/export-log*）归 logs/
    private func moveAuxFilesToLogs(root: URL) {
        let fm = FileManager.default
        let logs = SharedIn.logsDirectory(root)
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in items {
            let name = url.lastPathComponent
            let isAux = name.hasPrefix("share-") || name.hasPrefix("export-log")
            guard isAux, !url.hasDirectoryPath else { continue }
            try? fm.moveItem(at: url, to: logs.appendingPathComponent(name))
        }
    }

    // MARK: - 手机上占用了多少

    struct StorageScan {
        var photos = 0
        var bytes: Int64 = 0
        var scanned = false
    }

    @Published var storageScan = StorageScan()
    @Published var scanningStorage = false

    /// 实测手机端存的照片数与字节（store/photos + Documents 的导入夹/Inbox/散落文件）——
    /// 「清理干净没有」不用猜：照片 0 个 = 干净；比待拉取数多 = 有已拉取未清或残留。
    func refreshStorage() {
        guard !scanningStorage else { return }
        scanningStorage = true
        let store = AppStorage.storeURL
        let documents = AppStorage.documentsURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var scan = StorageScan()
            let fm = FileManager.default
            let logsPrefix = SharedIn.logsDirectory(store).path + "/"
            for root in [store, documents] {
                if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let url as URL in walker {
                        let path = url.path
                        if path.hasPrefix(logsPrefix) || path == store.appendingPathComponent("manifest.csv").path { continue }
                        guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                              vals.isRegularFile == true else { continue }
                        scan.photos += 1
                        scan.bytes += Int64(vals.fileSize ?? 0)
                    }
                }
            }
            scan.scanned = true
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningStorage = false
                self.storageScan = scan
            }
        }
    }

    // MARK: - 清理已拉取

    /// 确认电脑端已拉取并校验 PASS 后，删掉手机端全部照片文件腾空间：
    /// 清单里 OK 的行改记 PULLED（哈希保留，证明链不断），清单外的残留一并扫掉——
    /// 「清理干净没有」从此不用猜，看占用卡的照片数归零即可。
    func cleanExportedFiles() {
        guard !cleaning else { return }
        cleaning = true
        let root = AppStorage.storeURL
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
            // 扫尾：photos/ 里清单外的残留照片也一并清掉（含已拉取未清的）
            let photosRoot = root.appendingPathComponent("photos", isDirectory: true)
            if let walker = fm.enumerator(at: photosRoot, includingPropertiesForKeys: nil) {
                for case let url as URL in walker where !url.hasDirectoryPath {
                    let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
                    guard (try? fm.removeItem(at: url)) != nil else {
                        result.failed += 1
                        continue
                    }
                    result.orphans += 1
                    result.bytes += size
                }
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
                self.refreshStorage()
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
