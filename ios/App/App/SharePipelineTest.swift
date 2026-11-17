#if DEBUG
import Foundation

/// 分享导入链路自测（-autoTest 时跑）：直接往 App Group 收件箱按扩展的两种历史
/// 队列格式投文件，验证 drain 的解析/落位/登记/孤儿补收/重复跳过/队列重写。
/// CI 模拟器能过 = 代码链路本身没问题；真机还 0 项时只剩「容器不一致」一种解释。
enum SharePipelineTest {

    private struct Ctx {
        let docs: URL
        let manifest: URL
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
            return [TestOutcome(name: "分享导入链路: 容器可用", passed: false,
                                detail: SharedGroup.lastProbeDescription)]
        }
        let ctx = Ctx(docs: docs, manifest: docs.appendingPathComponent("manifest.csv"),
                      inbox: inbox, queue: queue)
        clean(ctx.inbox, ctx.queue)
        defer {
            clean(ctx.inbox, ctx.queue)
            try? fm.removeItem(at: base)
        }

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
        func manifestRows() -> Int {
            ManifestStore.load(url: ctx.manifest).0.count
        }

        record("分享导入链路: 新版字典队列行") {
            try writeFile("IMG_9001.JPG", byte: 0x11, ctx: ctx)
            try writeQueue(["{\"file\":\"IMG_9001.JPG\",\"note\":\"单元测试\"}"], ctx: ctx)
            let n = SharedIn.drain(documentsURL: ctx.docs, manifestURL: ctx.manifest).imported
            try require(n == 1, "imported=\(n)")
            try require(manifestRows() == 1, "manifest 应 1 行")
            try require(!FileManager.default.fileExists(atPath: ctx.queue.path), "队列应被清空删除")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: ctx.inbox.path)) ?? []
            try require(names.isEmpty, "收件箱应清空，剩 \(names)")
        }

        record("分享导入链路: 数组队列行（扩展旧版格式）") {
            try writeFile("IMG_9002.JPG", byte: 0x22, ctx: ctx)
            try writeQueue(["[{\"file\":\"IMG_9002.JPG\",\"note\":\"\"}]"], ctx: ctx)
            let n = SharedIn.drain(documentsURL: ctx.docs, manifestURL: ctx.manifest).imported
            try require(n == 1, "imported=\(n)")
            try require(manifestRows() == 2, "manifest 应 2 行")
        }

        record("分享导入链路: 收件箱孤儿文件补收") {
            try writeFile("IMG_9003.JPG", byte: 0x33, ctx: ctx)
            let n = SharedIn.drain(documentsURL: ctx.docs, manifestURL: ctx.manifest).imported
            try require(n == 1, "imported=\(n)")
            try require(manifestRows() == 3, "manifest 应 3 行")
        }

        record("分享导入链路: 重复内容跳过且不重复登记") {
            try writeFile("IMG_9003.JPG", byte: 0x33, ctx: ctx) // 同名同哈希再来一次
            try writeQueue(["{\"file\":\"IMG_9003.JPG\",\"note\":\"\"}"], ctx: ctx)
            let n = SharedIn.drain(documentsURL: ctx.docs, manifestURL: ctx.manifest).imported
            try require(n == 0, "重复应跳过，imported=\(n)")
            try require(manifestRows() == 3, "manifest 行数不应变")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: ctx.inbox.path)) ?? []
            try require(names.isEmpty, "重复文件也应从收件箱移除，剩 \(names)")
        }

        return outs
    }

    private static func writeFile(_ name: String, byte: UInt8, ctx: Ctx) throws {
        try Data(repeating: byte, count: 256).write(to: ctx.inbox.appendingPathComponent(name))
    }

    private static func writeQueue(_ lines: [String], ctx: Ctx) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: ctx.queue)
    }

    private static func clean(_ inbox: URL, _ queue: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? [] {
            try? fm.removeItem(at: inbox.appendingPathComponent(name))
        }
        try? fm.removeItem(at: queue)
    }
}
#endif
