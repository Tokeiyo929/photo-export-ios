import Foundation
#if DEBUG

/// -autoSmoke 巡访：与 tests/run_simulator_tests.sh 的握手协议一致。
/// 协议：App 写 tmp/smoke/now-<name> → runner 截图后写回 ack-<name> → 下一页。
/// 注意目录是 mode 名 smoke，不是参数名 -autoSmoke。
final class SmokeTour {
    static let shared = SmokeTour()
    static let pages = ["01-home", "02-export", "03-manifest", "04-pc-guide"]
    static let pageTabs = [0, 0, 1, 2]

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
        state.refreshLibrary() // 权限已由 runner 的 simctl privacy grant 预授权
        runPage(0)
    }

    // MARK: - 逐页

    private func runPage(_ index: Int) {
        guard let state, index < Self.pages.count else {
            finish()
            return
        }
        let name = Self.pages[index]
        state.selectedTab = Self.pageTabs[index]
        print("PE SMOKE: page \(name)")
        switch name {
        case "01-home":
            // 等 simctl addmedia 注入的 fixture 出现在相册里
            waitUntil(timeout: 120,
                      check: { state.libraryCount > 0 },
                      onTimeout: { "相册为空（simctl addmedia 未生效或权限未授予）" }) { [weak self] in
                self?.showMarker(index)
            }
        case "02-export":
            state.startExport()
            waitUntil(timeout: 600,
                      check: { !state.exportRunning && state.lastFinished != nil },
                      onTimeout: { "导出 600s 未结束" }) { [weak self] in
                guard let self, let summary = state.lastFinished else { return }
                if summary.failed > 0 || summary.ok == 0 {
                    fail("导出结果异常 ok=\(summary.ok) failed=\(summary.failed) —— "
                         + summary.errors.joined(separator: "; "))
                } else {
                    showMarker(index)
                }
            }
        case "03-manifest":
            state.loadManifest()
            delay(0.8) { [weak self] in self?.showMarker(index) }
        default: // 04-pc-guide
            delay(0.8) { [weak self] in self?.showMarker(index) }
        }
    }

    private func showMarker(_ index: Int) {
        let name = Self.pages[index]
        writeMarker("now-\(name)")
        waitUntil(timeout: 180,
                  check: { FileManager.default.fileExists(atPath: smokeDir.appendingPathComponent("ack-\(name)").path) },
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
