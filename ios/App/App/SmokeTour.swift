import Foundation
import UIKit
#if DEBUG

/// -autoSmoke 巡访：与 tests/run_simulator_tests.sh 的握手协议一致。
/// 协议：App 写 tmp/smoke/now-<name> → runner 截图后写回 ack-<name> → 下一页。
/// 注意目录是 mode 名 smoke，不是参数名 -autoSmoke。
///
/// 产品收缩（2026-11）后没有全量导出页：smoke 的「真实链路」改为模拟分享扩展——
/// 往 App Group 收件箱投两张 PNG + 记账（与扩展落盘/入队完全同构），再走真实
/// drainSharedInbox 登记。这样 CI 验的正是产品主链路：收件箱→哈希→归档→清单。
final class SmokeTour {
    static let shared = SmokeTour()
    static let pages = ["01-home", "02-share-import"]

    private weak var state: AppState?
    private var smokeDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smoke")
    }

    func begin(state: AppState) {
        self.state = state
        try? FileManager.default.createDirectory(at: smokeDir, withIntermediateDirectories: true)
        for name in Self.pages {
            try? FileManager.default.removeItem(at: smokeDir.appendingPathComponent("now-\(name)"))
            try? FileManager.default.removeItem(at: smokeDir.appendingPathComponent("ack-\(name)"))
        }
        try? FileManager.default.removeItem(at: smokeDir.appendingPathComponent("done.txt"))
        try? FileManager.default.removeItem(at: smokeDir.appendingPathComponent("result.txt"))
        print("PE SMOKE: begin pages=\(Self.pages)")
        runPage(0)
    }

    // MARK: - 逐页

    private func runPage(_ index: Int) {
        guard let state, index < Self.pages.count else {
            finish()
            return
        }
        let name = Self.pages[index]
        print("PE SMOKE: page \(name)")
        switch name {
        case "01-home":
            delay(0.8) { [weak self] in self?.showMarker(index) } // 等首页卡片渲染完再截
        default: // 02-share-import
            importShareFixtures(index: index)
        }
    }

    /// 模拟用户主链路：两张 PNG 存进「导入」文件夹（与相册存储到文件同构），
    /// 然后走真实的 drainSharedInbox。断言清单里出现 ≥2 行 OK。
    private func importShareFixtures(index: Int) {
        guard let state else { fail("AppState 丢失"); return }
        let importDir = AppStorage.importFolderURL
        func pngData(_ color: UIColor, width: CGFloat, height: CGFloat) -> Data? {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
            return renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }.pngData()
        }
        guard let red = pngData(UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1), width: 64, height: 64),
              let blue = pngData(UIColor(red: 0.16, green: 0.35, blue: 0.86, alpha: 1), width: 48, height: 48) else {
            fail("fixture PNG 生成失败")
            return
        }
        for (name, data) in [("IMG_9001.PNG", red), ("IMG_9002.PNG", blue)] {
            do {
                try data.write(to: importDir.appendingPathComponent(name), options: .atomic)
            } catch {
                fail("fixture 写导入夹失败：\(error)")
                return
            }
        }
        ExportLog.write("SMOKE fixtures planted=2 importDir=\(importDir.path)")
        state.drainSharedInbox()
        waitUntil(timeout: 120,
                  check: { state.manifestStats.okCount >= 2 },
                  onTimeout: { "分享导入 120s 未登记 2 项 diag=\(state.shareDiag) last=\(state.shareLastLine)" }) { [weak self] in
            guard let self else { return }
            // 等主队列把卡片文案刷出来再截图（drain 结果在 DispatchQueue.main.async 落地）
            self.delay(0.8) { self.showMarker(index) }
        }
    }

    private func showMarker(_ index: Int) {
        let name = Self.pages[index]
        writeMarker("now-\(name)")
        waitUntil(timeout: 180,
                  check: { [weak self] in FileManager.default.fileExists(atPath: self?.smokeDir.appendingPathComponent("ack-\(name)").path ?? "/nonexistent") },
                  onTimeout: { "runner 未 ack \(name)" }) { [weak self] in
            self?.runPage(index + 1)
        }
    }

    // MARK: - 小工具（主线程轮询）

    private func delay(_ seconds: TimeInterval, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: then)
    }

    private func waitUntil(timeout: TimeInterval,
                           check: @escaping () -> Bool,
                           onTimeout: @escaping () -> String,
                           then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        poll(deadline: deadline, check: check, onTimeout: onTimeout, then: then)
    }

    private func poll(deadline: Date,
                      check: @escaping () -> Bool,
                      onTimeout: @escaping () -> String,
                      then: @escaping () -> Void) {
        if check() {
            then()
            return
        }
        if Date() >= deadline {
            fail(onTimeout())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.poll(deadline: deadline, check: check, onTimeout: onTimeout, then: then)
        }
    }

    private func writeMarker(_ name: String) {
        FileManager.default.createFile(atPath: smokeDir.appendingPathComponent(name).path, contents: nil)
        print("PE SMOKE: marker \(name)")
    }

    private func write(_ file: String, _ content: String) {
        try? content.data(using: .utf8)?.write(to: smokeDir.appendingPathComponent(file), options: .atomic)
    }

    private func finish() -> Never {
        print("PE SMOKE: finish，写 result/done 后退出")
        write("result.txt", "RESULT: ALL PASS")
        write("done.txt", "PASS")
        exit(0)
    }

    private func fail(_ message: String) -> Never {
        print("PE SMOKE: FAIL \(message)")
        write("result.txt", "FAIL smoke —— \(message)\nRESULT: 1 FAILURES")
        write("done.txt", "FAIL")
        exit(1)
    }
}

#endif
