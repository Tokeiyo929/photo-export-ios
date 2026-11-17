import SwiftUI

/// 分享导出主页：相册分享进来的原片在这里登记、清点、传去电脑。
/// 产品收缩（2026-11）：全量导出与 PHPicker 补漏下线，只保留分享导入这一条入口。
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showCleanConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    shareCard
                    storageCard
                }
                .padding(16)
            }
            .navigationTitle("照片无损导出")
            .onAppear {
                state.drainSharedInbox()   // 刷新「分享导入」卡片状态
                state.refreshStorage()     // 实测占用
            }
            .alert("确认清空照片？", isPresented: $showCleanConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除全部照片文件", role: .destructive) {
                    state.cleanExportedFiles()
                }
            } message: {
                Text("红线：确认电脑端已拉取并校验全 PASS 再删——删除后手机端不再有这些照片（清单哈希保留，证明链不断），将释放约 \(bytesString(state.storageScan.bytes))。")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("相册分享 → 本 App 登记 → 电脑拉取校验 · 字节级复制 · SHA-256 可证明")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("构建 \(state.buildLabel) · 工作日志 export-log.txt 在「文件」里可见")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// 「分享导入」状态卡：分享扩展写完文件后回首页要有反馈——此前 sharedImportedCount
    /// 只赋值不显示，用户以为没反应。容器不可用时直接写明探测详情并指路直投通道。
    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("分享导入", systemImage: "square.and.arrow.down.on.square")
                .font(.headline)
            if state.shareContainerOK {
                Text(state.sharePending > 0
                     ? "收件箱还有 \(state.sharePending) 项待登记（点「立即登记」或重开 App）"
                     : "收件箱已清空")
                    .font(.subheadline)
                Text("主 App 容器：\(state.shareGroup.isEmpty ? "未定位" : state.shareGroup)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if !state.shareDiag.isEmpty {
                    Text(state.shareDiag)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if !state.shareLastLine.isEmpty {
                    Text(state.shareLastLine)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if !state.shareExtLine.isEmpty {
                    Text("扩展侧最后一条：\(state.shareExtLine)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("立即登记") { state.drainSharedInbox() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
            } else {
                Text("共享容器不可用（App Group 没注册上）")
                    .font(.subheadline)
                    .foregroundColor(.red)
                Text(state.shareProbe)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if !state.shareExtLine.isEmpty {
                    Text("扩展侧最后一条：\(state.shareExtLine)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text("替代：分享面板 App 行点「照片无损导出」直接投递")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    /// 「手机上占用」卡：实测 Documents 里的照片数与字节，一键清空。
    /// 「清理干净没有」不用猜：照片 0 个 = 干净；比待拉取数多 = 有残留。
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("手机上占用", systemImage: "internaldrive")
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
            Text("清单：待拉取 \(state.manifestStats.okCount) · 已拉取清理 \(state.manifestStats.pulledCount)"
                 + (state.manifestStats.failCount > 0 ? " · 失败 \(state.manifestStats.failCount)" : ""))
                .font(.footnote)
                .foregroundColor(.secondary)
            if state.storageScan.scanned, state.storageScan.photos > state.manifestStats.okCount {
                Text("其中 \(state.storageScan.photos - state.manifestStats.okCount) 个不在待拉取清单（已拉取未清或残留），清空会一并删掉")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if state.storageScan.scanned, state.storageScan.photos == 0 {
                Text("已清干净：App 里没有存任何照片")
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
                    Label("清空手机端照片文件", systemImage: "trash")
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
        var text = "清理完成：删除 \(result.cleaned + result.orphans) 个，释放 \(bytesString(result.bytes))"
        if result.orphans > 0 { text += "（含 \(result.orphans) 个清单外残留）" }
        if result.absent > 0 { text += "，\(result.absent) 个本就不在（改记 PULLED）" }
        if result.failed > 0 { text += "，\(result.failed) 个删除失败（下次再试）" }
        return text
    }

}
