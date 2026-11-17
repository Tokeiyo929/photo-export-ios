import SwiftUI
import UIKit

@main
struct PhotoExportApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onChange(of: scenePhase) { phase in
                    // 熄屏/切后台取证：锁屏时依次 inactive→background。
                    let name: String
                    switch phase {
                    case .active: name = "active"
                    case .inactive: name = "inactive"
                    case .background: name = "background"
                    @unknown default: name = "unknown"
                    }
                    if phase == .active {
                        state.drainSharedInbox() // 相册分享来的文件落位登记
                    }
                    ExportLog.write("LIFECYCLE \(name)")
                }
        }
    }
}

/// 单页 App：分享导入 + 清理已拉取（产品收缩 2026-11 二次收敛后无页签）。
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HomeView()
            // Documents/Inbox 兜底扫描：冷启动经「分享面板直投」拉起时 scenePhase 没有
            // 变化回调，onChange 不会触发——这里补一次；已运行时报 URL 也立刻收。
            .onAppear { state.drainSharedInbox() }
            .onOpenURL { state.receiveOpenIn($0) }
    }
}
