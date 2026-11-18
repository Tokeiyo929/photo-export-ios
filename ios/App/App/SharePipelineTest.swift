#if DEBUG
import Foundation

/// 导入链路自测（-autoTest 时跑，v4 传送带语义）：
/// ①导入夹文件全部入暂存 ②同名不同内容防撞名 ③扩展收件箱无队列也收+队列销毁。
/// 没有清单可断言——断言暂存区里的文件本身。
enum SharePipelineTest {

    private struct Ctx {
        let docs: URL
        let inbox: URL
        let queue: URL
    }

    static func run() -> [TestOutcome] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sharepipe-\(UUID().uuidString)")
        let docs = base.appendingPathComponent("Documents", isDirectory: true)
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        guard let inbox = SharedGroup.inboxDirectory(), let queue = SharedGroup.queueURL() else {
            try? fm.removeItem(at: base)
            return [TestOutcome(name: "导入链路: 容器可用", passed: false,
                                detail: SharedGroup.lastProbeDescription)]
        }
        let ctx = Ctx(docs: docs, inbox: inbox, queue: queue)
        cleanGroupInbox(ctx)
        defer { cleanGroupInbox(ctx); try? fm.removeItem(at: base) }

        var outs: [TestOutcome] = []
        func record(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                outs.append(TestOutcome(name: name, passed: true, detail: ""))
            } catch {
                outs.append(TestOutcome(name: name, passed: false, detail: String(describing: error)))
            }
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "SharePipelineTest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func stagedFiles() -> [String] {
            var names: [String] = []
            if let walker = fm.enumerator(at: ctx.docs.appendingPathComponent("photos"),
                                          includingPropertiesForKeys: nil) {
                for case let url as URL in walker where !url.hasDirectoryPath {
                    names.append(url.lastPathComponent)
                }
            }
            return names.sorted()
        }
        func rootStrays() -> [String] {
            let names = (try? fm.contentsOfDirectory(atPath: ctx.docs.path)) ?? [String]()
            return names.filter { name in
                guard !name.hasPrefix(".") else { return false }
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: ctx.docs.appendingPathComponent(name).path,
                                     isDirectory: &isDir) && !isDir.boolValue
            }
        }

        record("导入链路: 导入夹与根散落文件全部入暂存") {
            try Data(repeating: 0x11, count: 256).write(to: ctx.docs.appendingPathComponent("导入").appendingPathComponent("A_9001.JPG"))
            try Data(repeating: 0x22, count: 256).write(to: ctx.docs.appendingPathComponent("B_9002.jpg"))
            let n = SharedIn.drainImportFolder(documentsURL: ctx.docs, storeURL: ctx.docs).imported
            try require(n == 2, "imported=\(n)")
            let staged = stagedFiles()
            try require(staged == ["A_9001.JPG", "B_9002.jpg"], "暂存区应有两个文件，得到 \(staged)")
            try require(rootStrays().isEmpty, "根散落文件应被收走，剩 \(rootStrays())")
        }

        record("导入链路: 同名不同内容防撞名") {
            let dir = ctx.docs.appendingPathComponent("导入", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x33, count: 256).write(to: dir.appendingPathComponent("C_9003.HEIC"))
            try Data(repeating: 0x44, count: 512).write(to: dir.appendingPathComponent("C_9003 (1).HEIC"))
            _ = SharedIn.drainImportFolder(documentsURL: ctx.docs, storeURL: ctx.docs)
            let cFiles = stagedFiles().filter { $0.hasPrefix("C_9003") }
            try require(cFiles.count == 2, "同名应共存不覆盖，得到 \(cFiles)")
        }

        record("导入链路: 扩展收件箱无队列也收且队列销毁") {
            try Data(repeating: 0x55, count: 256).write(to: ctx.inbox.appendingPathComponent("D_9004.PNG"))
            try Data("{\"file\":\"D_9004.PNG\"}".utf8).write(to: ctx.queue)
            let n = SharedIn.drain(storeURL: ctx.docs).imported
            try require(n == 1, "imported=\(n)")
            try require(stagedFiles().contains("D_9004.PNG"), "收件箱文件应入暂存")
            try require(!fm.fileExists(atPath: ctx.queue.path), "队列文件应被销毁")
            let left = (try? fm.contentsOfDirectory(atPath: ctx.inbox.path)) ?? []
            try require(left.isEmpty, "收件箱应清空，剩 \(left)")
        }

        return outs
    }

    private static func cleanGroupInbox(_ ctx: Ctx) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: ctx.inbox.path)) ?? [] {
            try? fm.removeItem(at: ctx.inbox.appendingPathComponent(name))
        }
        try? fm.removeItem(at: ctx.queue)
    }
}
#endif
