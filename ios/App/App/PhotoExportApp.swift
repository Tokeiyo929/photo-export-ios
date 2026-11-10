import SwiftUI

@main
struct PhotoExportApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}

/// 三个页签：导出 / 记录 / 电脑拉取指南。
/// selectedTab 放在 AppState 里，供 SmokeTour 按页签巡访。
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            HomeView()
                .tabItem { Label("导出", systemImage: "square.and.arrow.down") }
                .tag(0)
            ManifestView()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }
                .tag(1)
            PcGuideView()
                .tabItem { Label("电脑", systemImage: "desktopcomputer") }
                .tag(2)
        }
    }
}
