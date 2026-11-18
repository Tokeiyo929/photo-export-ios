import SwiftUI

/// 主页（v4 传送带）：相册存进「导入」夹 → 自动搬进暂存区 → 电脑拉取 → 清空归零。
/// 手机端没有账本：「待送电脑 N 个」就是暂存区的实测文件数。
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showCleanConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    importCard
                    storageCard
                }
                .padding(16)
            }
            .navigationTitle("照片无损导出")
            .onAppear {
                state.drainSharedInbox()   // 三个入口的收件落位（秒级移动）
                state.refreshStorage()     // 实测占用（30s 节流）
            }
            .alert("确认清空暂存区？", isPresented: $showCleanConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除全部照片文件", role: .destructive) {
                    state.cleanStaging()
                }
            } message: {
                Text("红线：确认电脑端已拉取并校验全 PASS 再删——删除后手机端不再有这些照片（电脑端 export-report.csv 留有全部哈希记录），将释放约 \(bytesString(state.storageScan.bytes))。")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("相册 → 存储到「导入」文件夹 → 自动入暂存区 → 电脑拉取校验 · 字节级原片")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("构建 \(state.buildLabel) · 手机端只是传送带：拉完清空，不留账本")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// 「导入照片」卡：主通道三步 + 实时进度（逐文件 x/y）+ 结果。
    private var importCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("导入照片", systemImage: "square.and.arrow.down.on.square")
                .font(.headline)
            Text("① 相册选片 → 分享 → **存储到文件**\n② 选「我的 iPhone」→「照片无损导出」→「导入」\n③ 打开本 App，自动搬进暂存区")
                .font(.subheadline)
            Text("导入结果：\(state.shareLastLine.isEmpty ? "还没有过" : state.shareLastLine)")
                .font(.footnote)
                .foregroundColor(.secondary)
            if !state.shareDiag.isEmpty {
                Text(state.shareDiag)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Button("立即导入") { state.drainSharedInbox() }
                .font(.footnote)
                .buttonStyle(.bordered)
            Text("备选：分享面板点「照片无损导出」App 图标（直投）/ 分享扩展按钮，都会汇入暂存区")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    /// 「手机上占用」卡：待送电脑 N 个 · X MB。拉完清空归零——传送带语义。
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("待送电脑", systemImage: "internaldrive")
                .font(.headline)
            if state.storageScan.scanned {
                Text("照片 \(state.storageScan.photos) 个 · \(bytesString(state.storageScan.bytes))")
                    .font(.subheadline)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("统计中…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            if state.storageScan.scanned, state.storageScan.photos == 0 {
                Text("暂存区是空的：手机上没有存任何照片")
                    .font(.footnote)
                    .foregroundColor(.green)
            }
            if let result = state.cleanResult {
                Text(cleanResultText(result))
                    .font(.footnote)
                    .foregroundColor(result.failed == 0 ? .green : .orange)
            }
            Button(role: .destructive) {
                showCleanConfirm = true
            } label: {
                if state.cleaning {
                    HStack { ProgressView(); Text("清理中…") }
                } else {
                    Label("清空暂存区（电脑拉完之后）", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .disabled(state.cleaning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func cleanResultText(_ result: CleanResult) -> String {
        var text = "清理完成：删除 \(result.deleted) 个，释放 \(bytesString(result.bytes))"
        if result.failed > 0 { text += "，\(result.failed) 个删除失败（下次再试）" }
        return text
    }

}
