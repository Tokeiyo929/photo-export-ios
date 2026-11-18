import SwiftUI
import UIKit

/// 「清空暂存区」的结果。
struct CleanResult {
    var deleted = 0
    var bytes: Int64 = 0
    var failed = 0
}

/// 中心状态（v4 传送带，2026-11-18）。
/// 约定：所有 @Published 只在主线程写（其余地方用 DispatchQueue.main.async）。
/// 手机端没有账本：导入=移动文件进暂存区，拉取/对账/哈希全在电脑端。
final class AppState: ObservableObject {

    @Published var cleaning = false
    @Published var cleanResult: CleanResult?

    private var autoTestScheduled = false

    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// 首页「导入照片」卡片状态
    @Published var sharePending = 0
    @Published var shareContainerOK = true
    @Published var shareProbe = ""
    @Published var shareLastLine = ""
    @Published var shareExtLine = ""
    /// 一次截图定位 0 项原因：主 App 落到的组名 + 收件/导入摘要
    @Published var shareGroup = ""
    @Published var shareDiag = ""

    /// 「导入」文件夹（主通道）+ 分享扩展 + 直投 Inbox 的收件落位：
    /// 全部只是**移动文件**进暂存区 photos/日期/（零哈希零账本，秒级）。
    func drainSharedInbox() {
        let documents = AppStorage.documentsURL
        let store = AppStorage.storeURL
        _ = AppStorage.importFolderURL // 顺手保证「导入」文件夹在文件 App 里可见
        shareLastLine = "正在导入…" // 点按钮立即有反馈
        Task.detached(priority: .utility) { [weak self] in
            let progress: (Int, Int, String) -> Void = { done, total, name in
                DispatchQueue.main.async {
                    self?.shareLastLine = "正在导入 \(done)/\(total)：\(name)"
                }
            }
            // 三条通道都收：①文件 App「导入」文件夹（相册→存储到文件，主通道）
            // ②App Group 收件箱（分享扩展）③Documents/Inbox（分享面板直投）
            let ext = SharedIn.drain(storeURL: store, onFile: progress)
            let openIn = SharedIn.drainOpenInInbox(documentsURL: documents, storeURL: store, onFile: progress)
            let folder = SharedIn.drainImportFolder(documentsURL: documents, storeURL: store, onFile: progress)
            let imported = ext.imported + openIn.imported + folder.imported
            let failed = ext.failed + openIn.failed + folder.failed
            // 卡片状态每次都刷（哪怕 0 条）：用户分享完回首页要有反馈，不能一片空白
            let ok = SharedGroup.container() != nil
            let pending = SharedGroup.pendingCount()
            let probe = SharedGroup.lastProbeDescription
            let group = SharedGroup.resolvedGroupName
            let diag = SharedIn.lastDiagnostics
            let stamp = Self.iso.string(from: Date())
            ExportLog.write("DRAIN staged=\(imported) failed=\(failed) pending=\(pending) containerOK=\(ok) probe=\(probe) diag=\(diag)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.shareContainerOK = ok
                self.sharePending = pending
                self.shareProbe = probe
                self.shareGroup = group
                self.shareDiag = diag
                self.shareExtLine = (try? String(contentsOf: SharedIn.extLastURL(store), encoding: .utf8)) ?? ""
                self.refreshStorage(force: true)
                if imported > 0 {
                    self.shareLastLine = "\(stamp) 已入暂存 \(imported) 个文件，等电脑拉取"
                        + (failed > 0 ? "；\(failed) 个失败留在原地，下次自动重试" : "")
                    try? Data(self.shareLastLine.utf8)
                        .write(to: SharedIn.lastResultURL(store))
                } else if failed > 0 {
                    self.shareLastLine = "\(stamp) \(failed) 个导入失败（见下方诊断）"
                } else {
                    self.shareLastLine = "\(stamp) 没有新文件"
                }
            }
        }
    }

    /// 分享面板直投：系统递来的文件 URL（in-place 原件需要 security-scope）。
    func receiveOpenIn(_ url: URL) {
        // photoexport://shared = 分享扩展拉起主 App 的信号（非文件），扫一遍即可
        guard url.isFileURL else {
            drainSharedInbox()
            return
        }
        let documents = AppStorage.documentsURL
        if url.path.hasPrefix(documents.appendingPathComponent("Inbox").path + "/")
            || url.path.hasPrefix(documents.appendingPathComponent("导入").path + "/") {
            drainSharedInbox()
            return
        }
        let store = AppStorage.storeURL
        Task.detached(priority: .utility) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var source = url
                // in-place 原件（Files/iCloud 地址）先拷进 Inbox 再搬——move 会把用户原目录
                // 里的文件搬走；不在沙盒里的路径同理只许拷不许移
                let insideDocuments = url.path.hasPrefix(documents.path + "/")
                if scoped || !insideDocuments {
                    let staged = documents.appendingPathComponent("Inbox", isDirectory: true)
                        .appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staged)
                    try FileManager.default.copyItem(at: url, to: staged)
                    source = staged
                }
                try SharedIn.moveStaged(source, storeURL: store)
                ExportLog.write("OPENIN url ok=\(url.lastPathComponent)")
                DispatchQueue.main.async {
                    self?.shareLastLine = "\(Self.iso.string(from: Date())) 已入暂存 1 个文件，等电脑拉取"
                    self?.refreshStorage(force: true)
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

    init() {
        bootstrap()
    }

    private func bootstrap() {
        setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：console 重定向到文件时也能逐行看到输出
        print("PE BOOT: args=\(ProcessInfo.processInfo.arguments) debug=\(_isDebugAssertConfiguration())")
        ExportLog.write("BOOT build=\(buildLabel) args=\(ProcessInfo.processInfo.arguments.joined(separator: " "))")
        // 迁移链（都幂等，按历史状态各取所需）：
        // ① 收编 Documents 根的散落年份目录/内部文件（无清单可改，纯移动）
        collectYearDirs(root: AppStorage.documentsURL)
        // ② photos//logs/ 搬进 App Support；旧账本 manifest.csv 归档进 logs/
        AppStorage.migrateLegacyDocuments()
        // ③ store 里万一也有散落目录（半途迁移等），同样收编
        collectYearDirs(root: AppStorage.storeURL)
        // ④ 「导入」文件夹必须在文件 App 里一直可见（用户的主入口）
        _ = AppStorage.importFolderURL
        // 首次占用统计（后台节流）
        refreshStorage()
        // 上次导入结果（跨重启可见）
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

    // MARK: - 目录布局（v4：内部文件住 App Support，Documents 只留「导入」文件夹）

    /// 收编（幂等，Documents 与 store 各跑一次）：老版本把照片年份目录和
    /// share-*/export-log* 散在根目录——年份目录整体挪进 photos/，内部文件挪进 logs/。
    /// 无账本可改（v4 不再有清单），纯移动。
    private func collectYearDirs(root: URL) {
        let fm = FileManager.default
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        if !fm.fileExists(atPath: photos.path) {
            try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        }
        var movedDirs: [String] = []
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in items {
                let name = url.lastPathComponent
                if name == "Inbox" || name == "photos" || name == "logs" || name == "导入" { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard (try? fm.moveItem(at: url, to: photos.appendingPathComponent(name))) != nil else { continue }
                movedDirs.append(name)
            }
        }
        moveAuxFilesToLogs(root: root)
        if !movedDirs.isEmpty {
            ExportLog.write("MIGRATE collect root=\(root.lastPathComponent) dirs=[\(movedDirs.joined(separator: ","))]")
        }
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
    /// 节流：全树枚举在千文件级也要几百毫秒，别每次回前台都跑（成熟同步客户端
    /// 从不在 UI 路径上 walk 文件系统——Nextcloud 只读索引库；这里用 30s 节流近似）
    private static var lastScanAt = Date.distantPast

    /// 实测暂存区（photos/）+ Documents 的导入夹/Inbox/散落文件的个数与字节——
    /// 「待送电脑 N 个」就是它。拉完清空归零，传送带语义一目了然。
    /// 顺带重建 index.txt（size<TAB>相对路径 一行一个）：iOS 27 的 AFC 列目录被拒
    /// （libimobiledevice#1490 生态问题），电脑只能按名读——这份清单就是拉取的枚举替代。
    /// 每次全量重建（不自增修补）：崩溃/半途状态自愈；暂存区常态很小，代价可忽略。
    func refreshStorage(force: Bool = false) {
        guard !scanningStorage else { return }
        guard force || Date().timeIntervalSince(Self.lastScanAt) >= 30 else { return }
        scanningStorage = true
        let store = AppStorage.storeURL
        let documents = AppStorage.documentsURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var scan = StorageScan()
            let fm = FileManager.default
            let logsPrefix = SharedIn.logsDirectory(store).path + "/"
            var indexLines: [String] = []
            let stagingPrefix = AppStorage.stagingURL.path + "/"
            for root in [store, documents] {
                if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let url as URL in walker {
                        let path = url.path
                        if path.hasPrefix(logsPrefix) { continue }
                        guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                              vals.isRegularFile == true else { continue }
                        scan.photos += 1
                        scan.bytes += Int64(vals.fileSize ?? 0)
                        if path.hasPrefix(stagingPrefix) {
                            let rel = String(path.dropFirst(stagingPrefix.count))
                            indexLines.append("\(vals.fileSize ?? 0)\t\(rel)")
                        }
                    }
                }
            }
            Self.lastScanAt = Date()
            scan.scanned = true
            try? indexLines.joined(separator: "\n").data(using: .utf8)
                .write(to: AppStorage.indexURL, options: .atomic)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningStorage = false
                self.storageScan = scan
            }
        }
    }

    // MARK: - 清空暂存区

    /// 拉取完成后的收尾：删掉暂存区 photos/ 全部文件，释放空间。
    /// 红线由 UI 确认框把守：确认电脑端已拉取并校验全 PASS。
    func cleanStaging() {
        guard !cleaning else { return }
        cleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var result = CleanResult()
            let photos = AppStorage.stagingURL
            if let walker = fm.enumerator(at: photos, includingPropertiesForKeys: nil) {
                for case let url as URL in walker where !url.hasDirectoryPath {
                    let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
                    guard (try? fm.removeItem(at: url)) != nil else {
                        result.failed += 1
                        continue
                    }
                    result.deleted += 1
                    result.bytes += size
                }
            }
            // 空日期目录顺手清掉，暂存区归零
            if let subdirs = try? fm.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil),
               subdirs.allSatisfy({ (try? fm.contentsOfDirectory(atPath: $0.path))?.isEmpty == true }) {
                for dir in subdirs { try? fm.removeItem(at: dir) }
            }
            ExportLog.write("CLEAN deleted=\(result.deleted) failed=\(result.failed) freed=\(result.bytes)")
            print("PE CLEAN: deleted=\(result.deleted) failed=\(result.failed) freed=\(result.bytes)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleaning = false
                self.cleanResult = result
                self.refreshStorage(force: true)
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
