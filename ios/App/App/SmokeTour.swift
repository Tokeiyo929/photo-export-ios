import Foundation
import Photos
import UIKit
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
            seedAndWaitForLibrary(index: index)
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

    /// 等 01-home 相册非空：优先指望 runner 的 simctl addmedia fixture；
    /// 数秒仍为 0 则用 PHAssetCreationRequest 自种两张真照片兜底
    /// （部分 iOS 模拟器 runtime 上 addmedia 不生效）。种出的资产走同一导出链路。
    private func seedAndWaitForLibrary(index: Int) {
        guard let state else { fail("AppState 丢失"); return }
        let deadline = Date().addingTimeInterval(120)
        var seeded = false
        var attempts = 0
        func tick() {
            if state.libraryCount > 0 {
                showMarker(index)
                return
            }
            if Date() >= deadline {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
                fail("相册为空 120s：authorizationStatus=\(status)"
                     + "（0=notDetermined 1=restricted 2=denied 3=authorized 4=limited）")
                return
            }
            attempts += 1
            if !seeded, attempts >= 12,
               PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                seeded = true
                print("PE SMOKE: 相册仍为空，DEBUG 自种 2 张测试照片")
                Self.seedSmokeAssets { _ in state.refreshLibrary() }
            }
            if attempts % 4 == 0 { state.refreshLibrary() } // 每 1s 重拉，覆盖 fetch 竞态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
        }
        tick()
    }

    /// DEBUG-only：往相册种两张纯色照片（红 64²、蓝 48²），写入的 .photo 资源
    /// 与真实照片走完全相同的 PHAssetResourceManager.writeData 导出链路。
    private static func seedSmokeAssets(completion: @escaping (Bool) -> Void) {
        func pngData(_ color: UIColor, width: CGFloat, height: CGFloat) -> Data? {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
            let image = renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            return image.pngData()
        }
        guard let red = pngData(UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1), width: 64, height: 64),
              let blue = pngData(UIColor(red: 0.16, green: 0.35, blue: 0.86, alpha: 1), width: 48, height: 48) else {
            completion(false)
            return
        }
        PHPhotoLibrary.shared().performChanges({
            for data in [red, blue] {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        }) { success, _ in completion(success) }
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
