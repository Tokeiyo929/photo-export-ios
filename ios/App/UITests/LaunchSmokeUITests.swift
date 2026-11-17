import XCTest

/// CI 模拟器无人值守自检。历史背景（run 5-8）：过去 App 首页会请求相册权限，
/// 靠 XCUITest interruption monitor 替人点「允许」。产品收缩（2026-11）后
/// App 不再读相册（分享导入拿系统递来的文件，无需权限），本测试转为
/// 「能装能启动能停在前台」的最低门槛——同时为 smoke 步骤完成 Debug 包构建。
final class LaunchSmokeUITests: XCTestCase {

    func testAppLaunchesAndStaysForeground() {
        let app = XCUIApplication()
        app.launch()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.state != .runningForeground {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(app.state, .runningForeground, "App 30s 内没到前台")
        // 留几秒给首屏渲染/收件箱 drain，顺带暴露启动即崩
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(app.state, .runningForeground, "App 启动数秒后退出（启动即崩）")
    }
}
