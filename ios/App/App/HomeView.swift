import SwiftUI

/// 导出主页：相册概况 → 开始导出 → 进度/结果 → 清理已拉取。
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showCleanConfirm = false
    @State private var auditLine: String?
    @State private var auditing = false
    @State private var showPicker = false
    @State private var pickerLine: String?
    @State private var picking = false
    @State private var pickDone = 0
    @State private var pickTotal = 0

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    libraryCard
                    exportSection
                    cleanCard
                    rescueCard
                    wifiCard
                    rulesCard
                }
                .padding(16)
            }
            .navigationTitle("照片无损导出")
            .onAppear { state.refreshLibrary() }
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
            Text("字节级复制 · SHA-256 可证明 · 按拍摄日期归档")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("构建 \(state.buildLabel) · 工作日志 export-log.txt 在「文件」里可见")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(permissionText, systemImage: permissionIcon)
                .font(.headline)
                .foregroundColor(state.authorization == .denied ? .red : .primary)
            if state.authorization == .authorized || state.authorization == .limited {
                Text(librarySummary)
                    .font(.subheadline)
                Text("本 App 可用空间 \(bytesString(state.freeBytes))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let warning = state.spaceWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            if state.authorization == .denied || state.authorization == .restricted {
                Text("去 设置 → 隐私与安全性 → 照片 → 打开「照片无损导出」")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var librarySummary: String {
        var range = ""
        if let earliest = state.libraryEarliest {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            var text = "最早 \(formatter.string(from: earliest))"
            if let latest = state.libraryLatest {
                text += " · 最晚 \(formatter.string(from: latest))"
            }
            range = " · " + text
        }
        if state.estimating { return "相册 \(state.libraryCount) 项\(range) · 预计统计中…" }
        if state.estimatedBytes > 0 { return "相册 \(state.libraryCount) 项\(range) · 预计 \(bytesString(state.estimatedBytes))" }
        return "相册 \(state.libraryCount) 项\(range) · 大库分批模式（逐批显示大小）"
    }

    private var permissionText: String {
        switch state.authorization {
        case .notDetermined: return "正在请求相册权限…"
        case .authorized: return "相册已授权"
        case .limited: return "相册受限访问（只导出所选照片）"
        case .denied: return "相册权限被拒绝"
        case .restricted: return "相册访问受限制"
        @unknown default: return "未知权限状态"
        }
    }

    private var permissionIcon: String {
        switch state.authorization {
        case .authorized, .limited: return "checkmark.seal"
        case .denied, .restricted: return "xmark.seal"
        default: return "hourglass"
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        // 档位选择器常驻：批次跑完后也要能改档（此前被结果卡片顶掉，下一批只能沿用旧档位）
        batchPicker
            .disabled(state.exportRunning)
        if state.exportRunning {
            runningCard
        } else if let summary = state.lastFinished {
            finishedCard(summary)
            Button {
                state.lastFinished = nil
                state.startExport()
            } label: {
                Text(summary.failed > 0 ? "重试失败文件" : "再次导出（增量续跑）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                state.startExport()
            } label: {
                Text("开始导出到本 App（数据线拉取前的第一步）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.authorization != .authorized && state.authorization != .limited
                      || state.libraryCount == 0)
        }
    }

    /// 分批导出：每批字节上限。装不下整个相册的机器，靠「导一批→拉取→清理」循环搬运全库。
    private var batchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每批导出上限（导一批 → 电脑拉取校验 → 清理 → 下一批）")
                .font(.footnote)
                .foregroundColor(.secondary)
            Picker("每批上限", selection: $state.batchMB) {
                Text("不限").tag(0)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
                Text("4 GB").tag(4096)
                Text("8 GB").tag(8192)
            }
            .pickerStyle(.segmented)
            if state.exportRunning {
                Text("引擎已按开始时刻的档位在跑，这里改的对下一批生效")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.progress.totalFiles == 0 {
                // 规划（扫描相册）阶段：总数还没定，用不定长进度 + 实时扫描计数
                ProgressView()
                Text(planningText)
                    .font(.subheadline)
                if state.planningTotal > 0 {
                    Text("已扫 \(state.planningScanned) / \(state.planningTotal) 项，扫描期间同样可以取消")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                ProgressView(value: progressFraction)
                Text("完成 \(state.progress.doneFiles) · 失败 \(state.progress.failedFiles) · 跳过 \(state.progress.skippedFiles) / 共 \(state.progress.totalFiles) 项")
                    .font(.subheadline)
                Text(bytesText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if !state.progress.currentFile.isEmpty {
                Text(state.progress.currentFile)
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("导出期间请保持 App 在前台（屏幕已常亮）；中断也没关系，重进自动续跑。")
                .font(.footnote)
                .foregroundColor(.orange)
            Button("取消导出", role: .destructive) { state.cancelExport() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var planningText: String {
        if state.planningTotal > 0 {
            return "正在扫描相册 \(state.planningScanned) / \(state.planningTotal)…"
        }
        return "正在扫描相册…（大相册首次扫描要一会儿，请稍候）"
    }

    private var progressFraction: Double? {
        guard state.progress.bytesTotal > 0 else { return nil }
        return Double(state.progress.bytesDone) / Double(state.progress.bytesTotal)
    }

    /// 总字节数在拷贝期才量得出（0 = 未知），未知时只显示已传
    private var bytesText: String {
        if state.progress.bytesTotal > 0 {
            return "已传 \(bytesString(state.progress.bytesDone)) / \(bytesString(state.progress.bytesTotal))"
        }
        return "已传 \(bytesString(state.progress.bytesDone))"
    }

    private func finishedCard(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(finishedTitle(summary),
                  systemImage: summary.allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(summary.allGood ? .green : .orange)
            Text("成功 \(summary.ok) · 失败 \(summary.failed) · 跳过(已导过) \(summary.skipped) · 共 \(bytesString(summary.bytesTotal))")
                .font(.subheadline)
            if summary.batchLimited {
                Label("本批已到字节上限，剩余照片下次「再次导出」继续", systemImage: "shippingbox.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if let reason = summary.stoppedReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if !summary.allGood {
                ForEach(summary.errors.prefix(5), id: \.self) { line in
                    Text(line)
                        .font(.footnote.monospaced())
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if summary.errors.count > 5 {
                    Text("… 共 \(summary.errors.count) 条失败，重跑会自动重试")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Text(nextStepText(summary))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func finishedTitle(_ summary: ExportSummary) -> String {
        if summary.cancelled { return "已取消" }
        if summary.stoppedReason != nil { return "本批提前结束（非错误）" }
        return summary.allGood ? "导出完成" : "完成（有失败项）"
    }

    private func nextStepText(_ summary: ExportSummary) -> String {
        if summary.batchLimited || summary.stoppedReason != nil {
            return "下一步：电脑拉取本批并校验全 PASS → 回本页点「清理已拉取文件」释放空间 → 再点「再次导出」继续下一批。"
        }
        return "下一步：去「电脑」页签，数据线拉取到电脑并校验。"
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
                .disabled(state.exportRunning || state.cleaning)
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

    /// 漏照片排查：先对账定位「相册看得见、全库抓取拿不到」的照片属于哪一类，
    /// 再用 PHPicker 补漏把它们接进同一条导出链。从电脑同步的照片 PhotoKit
    /// 对第三方拿不到是生态级限制（SO 32430410 十年悬案），PHPicker 是标准出路。
    private var rescueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("漏照片排查与补漏", systemImage: "questionmark.folder")
                .font(.headline)
            Text("相册 App 看得见、全库抓取却拿不到的照片（从电脑同步的、iCloud 共享相簿的），先对账定位，再挑图补进同一条导出链。")
                .font(.footnote)
                .foregroundColor(.secondary)
            if let line = auditLine {
                Text(line)
                    .font(.footnote)
            }
            Button {
                runAudit()
            } label: {
                Text(auditing ? "对账中…" : "图库对账")
            }
            .buttonStyle(.bordered)
            .disabled(auditing || state.exportRunning)
            Divider()
            if let line = pickerLine {
                Text(line)
                    .font(.footnote)
            }
            if picking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("接收中 \(pickDone)/\(pickTotal)…")
                        .font(.footnote)
                }
            }
            Button {
                showPicker = true
            } label: {
                Label("挑照片补漏导入", systemImage: "square.and.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(picking || state.exportRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .sheet(isPresented: $showPicker) {
            PickerSheet { providers in
                showPicker = false
                startPicking(providers)
            }
        }
    }

    private func runAudit() {
        auditing = true
        DispatchQueue.global(qos: .utility).async {
            let result = LibraryAudit.run()
            DispatchQueue.main.async {
                auditing = false
                auditLine = LibraryAudit.describe(result)
                ExportLog.write("AUDIT \(LibraryAudit.summary(result))")
            }
        }
    }

    private func startPicking(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        picking = true
        pickDone = 0
        pickTotal = providers.count
        pickerLine = nil
        _ = PickerIn.Session(providers: providers,
                             documentsURL: state.documentsURL,
                             manifestURL: state.manifestURL,
                             progress: { done, _ in
                                 pickDone = done
                             },
                             completion: { ok, skipped, failed in
                                 picking = false
                                 pickerLine = "补漏导入完成：新增 \(ok) · 重复跳过 \(skipped) · 失败 \(failed)"
                                     + (failed > 0 ? "（详情见工作日志 export-log.txt）" : "")
                             })
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
            bullet("不套用滤镜与裁剪编辑（编辑版是重新渲染的产物，与「原片无损」冲突）")
            bullet("按拍摄日期归档：2026/2026-03-15/IMG_1234.HEIC")
            bullet("每个文件写盘后、移动后各算一次 SHA-256，一致才记入清单")
            bullet("Live Photo 导出原片 + 实况视频两个文件；隐藏与最近删除不导出")
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
