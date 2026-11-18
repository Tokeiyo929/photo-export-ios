import Foundation

/// 存储布局 v3（2026-11-17）：内部文件全部住 Library/Application Support/PhotoExport
/// （文件 App **看不见**），Documents 里只留用户可见的「导入」文件夹。
/// 用户视角的文件 App 就一个「导入」——手机端目录精简的终点：
///   相册选片 → 分享 → 存储到文件 → On My iPhone/照片无损导出/导入 → 回 App 登记。
/// Inbox/（分享面板直投的系统落点）按系统约定必须在 Documents，只有真用过才会出现。
enum AppStorage {

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 内部文件根（index.txt / photos/ / logs/）
    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PhotoExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用户拖文件进来的文件夹（相册→分享→存储到文件→「导入」）。
    /// bootstrap 就创建：文件 App 里要一直看得见这个空文件夹。
    static var importFolderURL: URL {
        let dir = documentsURL.appendingPathComponent("导入", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 暂存区：等待电脑拉取的照片（photos/日期/…）。拉完清空，这就是它的全部语义。
    static var stagingURL: URL { storeURL.appendingPathComponent("photos", isDirectory: true) }

    /// 暂存区文件清单（size<TAB>相对路径）：iOS 27 AFC 列目录被拒，电脑按名读的枚举替代。
    /// 由占用统计的后台全树实测重建，不自增修补——崩溃自愈，清空后为空。
    static var indexURL: URL { storeURL.appendingPathComponent("index.txt") }

    /// v4 一次性迁移：Documents 里的 photos//logs/ 搬进 App Support；
    /// 旧账本 manifest.csv **归档**进 logs/（v4 传送带语义不再有清单，电脑端已有历史副本）。
    /// 幂等：photos 或 logs 已在 store 就不再动（半途残留下次补搬）。
    /// Inbox/（系统直投落点）留在 Documents——系统只往那里拷。
    static func migrateLegacyDocuments() {
        let fm = FileManager.default
        let docs = documentsURL
        let store = storeURL
        guard !fm.fileExists(atPath: store.appendingPathComponent("photos").path) else { return }
        var moved: [String] = []
        for name in ["photos", "logs"] {
            let src = docs.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = store.appendingPathComponent(name)
            try? fm.removeItem(at: dst) // 上次半途而废的残留先清掉再搬
            if (try? fm.moveItem(at: src, to: dst)) != nil { moved.append(name) }
        }
        // 旧账本归档：不再参与任何流程，留着给历史拉取对账
        let oldManifest = docs.appendingPathComponent("manifest.csv")
        if fm.fileExists(atPath: oldManifest.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            try? fm.moveItem(at: oldManifest,
                             to: SharedIn.logsDirectory(store).appendingPathComponent("manifest-archive-\(stamp).csv"))
            moved.append("manifest.csv(归档)")
        }
        if !moved.isEmpty {
            ExportLog.write("MIGRATE4 store=\(store.path) moved=[\(moved.joined(separator: ","))]")
        }
    }
}
