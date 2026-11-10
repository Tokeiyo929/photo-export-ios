import SwiftUI

/// 导出主页：相册概况 → 开始导出 → 进度/结果。
struct HomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    libraryCard
                    exportSection
                    rulesCard
                }
                .padding(16)
            }
            .navigationTitle("照片无损导出")
            .onAppear { state.refreshLibrary() }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("字节级复制 · SHA-256 可证明 · 按拍摄日期归档")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(permissionText, systemImage: permissionIcon)
                .font(.headline)
                .foregroundColor(state.authorization == .denied ? .red : .primary)
            if state.authorization == .authorized || state.authorization == .limited {
                Text("相册 \(state.libraryCount) 项 · 预计 \(state.estimating ? "统计中…" : bytesString(state.estimatedBytes))")
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

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progressFraction)
            Text("完成 \(state.progress.doneFiles + state.progress.skippedFiles) · 失败 \(state.progress.failedFiles) · 跳过 \(state.progress.skippedFiles) / 共 \(state.progress.totalFiles)")
                .font(.subheadline)
            Text("已传 \(bytesString(state.progress.bytesDone)) / \(bytesString(state.progress.bytesTotal))")
                .font(.footnote)
                .foregroundColor(.secondary)
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

    private var progressFraction: Double? {
        guard state.progress.bytesTotal > 0 else { return nil }
        return Double(state.progress.bytesDone) / Double(state.progress.bytesTotal)
    }

    private func finishedCard(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(summary.cancelled ? "已取消" : (summary.allGood ? "导出完成" : "完成（有失败项）"),
                  systemImage: summary.allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(summary.allGood ? .green : .orange)
            Text("成功 \(summary.ok) · 失败 \(summary.failed) · 跳过(已导过) \(summary.skipped) · 共 \(bytesString(summary.bytesTotal))")
                .font(.subheadline)
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
            Text("下一步：去「电脑」页签，数据线拉取到电脑并校验。")
                .font(.footnote)
                .foregroundColor(.secondary)
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
