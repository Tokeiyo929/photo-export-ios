import SwiftUI

/// 导出记录：manifest.csv 的设备侧视图 + 复核按钮。
struct ManifestView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已导出 \(state.manifestStats.okCount) 个文件 · 共 \(bytesString(state.manifestStats.bytes))")
                                .font(.subheadline)
                            if state.manifestStats.failCount > 0 {
                                Text("失败 \(state.manifestStats.failCount) 个（重跑自动重试）")
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                            if state.manifestStats.malformed > 0 {
                                Text("清单损坏行 \(state.manifestStats.malformed)")
                                    .font(.footnote)
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                    }
                    Button {
                        state.verifyExported()
                    } label: {
                        if state.verifying {
                            HStack { ProgressView(); Text("复核中…") }
                        } else {
                            Label("复核全部文件哈希", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(state.verifying || state.exportRunning || state.manifestStats.okCount == 0)
                    if state.verifyResult.finished {
                        if state.verifyResult.allGood {
                            Label("复核通过：\(state.verifyResult.checked) 个文件哈希一致", systemImage: "checkmark.seal.fill")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        } else {
                            Text("复核异常：一致 \(state.verifyResult.checked)，文件丢失 \(state.verifyResult.missing.count)，哈希不一致 \(state.verifyResult.mismatch.count)")
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("导出清单 manifest.csv")
                } footer: {
                    Text("电脑拉取后还会再校验一遍：manifest.csv 里的哈希 vs 电脑上文件的实际哈希，两条链路都一致才算无损送达。")
                }

                if state.manifestRows.isEmpty {
                    Section {
                        Text("还没有导出记录。去「导出」页开始。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("最近文件") {
                        ForEach(Array(state.manifestRows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Circle()
                                        .fill(row.status == "OK" ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(row.relativePath)
                                        .font(.footnote.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                HStack(spacing: 8) {
                                    Text(bytesString(row.size))
                                    Text(dateSourceText(row.dateSource))
                                    if row.favorite { Text("❤️") }
                                    Spacer()
                                    Text(row.status)
                                        .foregroundColor(row.status == "OK" ? .green : .red)
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                if row.status == "FAIL" && !row.note.isEmpty {
                                    Text(row.note)
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("记录")
            .onAppear { state.loadManifest() }
        }
        .navigationViewStyle(.stack)
    }

    private func dateSourceText(_ raw: String) -> String {
        switch raw {
        case "creation": return "拍摄时间"
        case "filetime": return "文件时间"
        default: return "无日期"
        }
    }
}
