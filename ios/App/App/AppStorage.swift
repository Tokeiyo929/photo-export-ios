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

    /// 内部文件根（manifest.csv / photos/ / logs/）
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

    static var manifestURL: URL { storeURL.appendingPathComponent("manifest.csv") }

    /// v3 一次性迁移：Documents 里的 manifest.csv/photos//logs/ 搬进 App Support。
    /// 幂等：store 里已有 manifest 就不动（半途残留文件也会在下次补搬）。
    /// Inbox/（系统直投落点）留在 Documents——系统只往那里拷。
    static func migrateLegacyDocuments() {
        let fm = FileManager.default
        let docs = documentsURL
        let store = storeURL
        guard !fm.fileExists(atPath: store.appendingPathComponent("manifest.csv").path) else { return }
        var moved: [String] = []
        for name in ["manifest.csv", "photos", "logs"] {
            let src = docs.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = store.appendingPathComponent(name)
            try? fm.removeItem(at: dst) // 上次半途而废的残留先清掉再搬
            if (try? fm.moveItem(at: src, to: dst)) != nil { moved.append(name) }
        }
        if !moved.isEmpty {
            ExportLog.write("MIGRATE3 store=\(store.path) moved=[\(moved.joined(separator: ","))]")
        }
    }
}
