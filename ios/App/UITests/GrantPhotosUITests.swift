import XCTest

/// CI 模拟器无人值守授权。背景（run 5-8 实测，iOS 26 runtime / Xcode 26）：
/// 宿主侧预授权全部无效——`simctl privacy grant photos` 报成功、TCC.db 直接写入
/// auth_value=2 的行也在，但 App 内 PHPhotoLibrary.authorizationStatus(.readWrite)
/// 始终 notDetermined（add-only 例外）。readWrite 授权只有权限弹窗能落。
/// 官方支持的无人值守路径 = XCUITest interruption monitor 替人点"允许"。
/// 授权按 bundle id 记在模拟器里，本测试跑完后 -autoSmoke 直接以已授权状态启动。
final class GrantPhotosUITests: XCTestCase {

    func testGrantPhotoLibraryAccess() {
        let app = XCUIApplication()
        app.launch() // 正常启动即触发 refreshLibrary → requestAuthorization → 弹窗

        var tappedButton: String?
        let monitor = addUIInterruptionMonitor(withDescription: "相册权限弹窗") { alert in
            let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
            print("PE GRANT: 弹窗按钮=\(labels)")
            // 各版本文案：iOS 17/18 "Allow Full Access"，iOS 26 "Allow All"（以打印为准迭代）
            let preferred = ["Allow Full Access", "Allow All", "Allow Access to All Photos", "Allow"]
            for name in preferred where alert.buttons[name].exists {
                alert.buttons[name].tap()
                tappedButton = name
                return true
            }
            // 兜底：按钮顺序里"完全允许"在最后（"Don't Allow"在最前）
            if let last = alert.buttons.allElementsBoundByIndex.last,
               !last.label.contains("Don't"),
               !last.label.contains("Limited"), !last.label.contains("Limited".lowercased()) {
                last.tap()
                tappedButton = last.label
                return true
            }
            return false
        }

        // interruption monitor 在弹窗出现后的下一次交互才触发；轮询多次覆盖弹窗出现时机
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, tappedButton == nil {
            app.tap()
            Thread.sleep(forTimeInterval: 1)
        }

        removeUIInterruptionMonitor(monitor)

        guard let tappedButton else {
            XCTFail("40s 内没点到相册权限弹窗：弹窗未出现或按钮文案未覆盖（见 PE GRANT 日志）")
            return
        }
        print("PE GRANT: 已点击「\(tappedButton)」，等待授权落库")
        Thread.sleep(forTimeInterval: 3)
    }
}
