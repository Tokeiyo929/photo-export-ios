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
                    cleanCard
                    wifiCard
                    rulesCard
                }
                .padding(16)
            }
            .navigationTitle("照片无损导出")
            .onAppear {
                state.drainSharedInbox()   // 刷新「分享导入」卡片状态
            }
            .alert("确认清理？", isPresented: $showCleanConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除 \(state.manifestStats.okCount) 个文件", role: .destructive) {
                    state.cleanExportedFiles()
                }
            } message: {
                Text("前提：电脑端已拉取本批文件，且 export-report.csv 全部 PASS。删除后手机端不再保留这些文件（清单里的哈希保留，证明链不断），将释放约 \(bytesString(state.manifestStats.bytes))。")
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

    /// 分批工作流的收尾一步：确认拉取校验 PASS 后，删手机端文件、清单改记 PULLED。
    @ViewBuilder
    private var cleanCard: some View {
        if state.manifestStats.okCount > 0 || state.cleaning {
            VStack(alignment: .leading, spacing: 8) {
                Label("已导出待拉取 \(state.manifestStats.okCount) 个 · \(bytesString(state.manifestStats.bytes))",
                      systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                Text("电脑端拉取并校验全 PASS 后，点这里删除手机端这些文件腾空间；清单改记 PULLED（哈希保留）。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button(role: .destructive) {
                    showCleanConfirm = true
                } label: {
                    if state.cleaning {
                        HStack { ProgressView(); Text("清理中…") }
                    } else {
                        Label("清理已拉取文件", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.cleaning)
                if let result = state.cleanResult {
                    Text(cleanResultText(result))
                        .font(.footnote)
                        .foregroundColor(result.failed == 0 ? .green : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private func cleanResultText(_ result: CleanResult) -> String {
        var text = "清理完成：删除 \(result.cleaned) 个，释放 \(bytesString(result.bytes))"
        if result.absent > 0 { text += "，\(result.absent) 个本就不在（改记 PULLED）" }
        if result.failed > 0 { text += "，\(result.failed) 个删除失败（保持 OK，下次再试）" }
        return text
    }

    /// WiFi 直传：iOS 27 数据线 AFC 通道对本 App 服务了错误的容器视图，
    /// WiFi 拉取（LocalSend 同款模式）是可靠通道，且通常比数据线快。
    private var wifiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("WiFi 直传到电脑", systemImage: "wifi")
                .font(.headline)
            if state.wifiRunning {
                if state.wifiURLs.isEmpty {
                    Text("已启动，但没拿到局域网 IP——确认手机连的是 WiFi（不是蜂窝网络）。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                } else {
                    ForEach(state.wifiURLs, id: \.self) { url in
                        Text(url)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("手机与电脑要在同一网络（电脑网线接同一路由器也行），然后三选一：\n① 命令行运行 pull.py --wifi --dest 目标目录（自动发现本机，推荐）\n② 命令行运行 pull.py --wifi 上面地址 --dest 目标目录（手动指定，自动按清单拉取并校验哈希）\n③ 浏览器打开上面地址手动下载（/list 看全部文件）\n台式机没无线网卡：手机开「个人热点」+ 数据线连电脑（装了 iTunes 自带 USB 网卡驱动），从上往下试上面列出的地址。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Button("关闭 WiFi 传图") { state.stopWifiServer() }
                    .buttonStyle(.bordered)
            } else {
                Text("数据线通道在你这台机抽风（系统把沙盒视图指错了容器）。开启后手机变成一台小型文件服务器，电脑通过 WiFi 直接拉取，推荐用起来。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button {
                    state.startWifiServer()
                } label: {
                    Label("开启 WiFi 传图", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("导出规则")
                .font(.headline)
            bullet("只复制原片字节：HEIC/JPEG/MOV 原样搬运，零转码、零重压缩")
            bullet("按拍摄日期归档：2026/2026-03-15/IMG_1234.HEIC")
            bullet("每个文件登记前算一次 SHA-256，电脑拉取时逐文件复算比对")
            bullet("同一张照片重复分享不会重复入库（按 内容哈希+文件名 跳过）")
            bullet("大批量分享时保持亮屏：息屏会暂停系统交接（扩展会尽力关自动锁屏）")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.accentColor)
            Text(text).font(.footnote)
        }
    }
}
