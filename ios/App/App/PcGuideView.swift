import SwiftUI

/// 电脑拉取指南：数据线（AFC 文件共享）两种方式 + 微信护甲说明。
struct PcGuideView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    step(number: "1", title: "数据线连接") {
                        text("手机用数据线连电脑并解锁。App 已把原片写入自己的「文件」目录：\n文件 App → 我的 iPhone → 照片无损导出 → 2026/2026-03-15/… + manifest.csv")
                    }
                    step(number: "2", title: "方式 A（推荐）：开源脚本拉取") {
                        code("pip install pymobiledevice3")
                        code("python pc/pull.py --app com.tokeiyo929.photoexport --dest D:\\相册导出")
                        text("脚本经数据线（usbmuxd/AFC）拉取全部文件，并逐个重算 SHA-256 与 manifest.csv 比对，生成 export-report.csv。加 --zip 顺带打包仅存储 ZIP。")
                    }
                    step(number: "3", title: "方式 B：爱思助手 / iMazing") {
                        text("爱思助手 → 应用游戏 → 本机 App → 照片无损导出 → 浏览文件 → 导出整个文件夹。拉回来后跑：")
                        code("python pc/verify.py D:\\相册导出")
                        text("同样逐文件校验哈希并出报告。")
                    }
                    step(number: "4", title: "微信护甲（仅存储 ZIP）") {
                        code("python pc/pull.py … --zip")
                        text("生成「仅存储（STORED）」模式的 ZIP：内容字节原封不动，只加目录结构。微信/QQ 里按「文件」发送 ZIP，对方解压后用同一份 manifest 校验，全程可证明无损。")
                    }
                    Text("红线：不要用微信/QQ 单发图片（即使选「原图」也无法保证字节不变，且不可验证）；不要用网盘「极速上传」。")
                        .font(.footnote)
                        .foregroundColor(.red)
                    Text("为什么导出期间要保持前台：iOS 会冻结后台 App，中断不打紧——manifest 就是断点，重进接着跑。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("电脑")
        }
        .navigationViewStyle(.stack)
    }

    private func step(number: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(number)
                    .font(.caption.bold())
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Circle())
                    .foregroundColor(.accentColor)
                Text(title).font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func text(_ content: String) -> some View {
        Text(content)
            .font(.footnote)
            .foregroundColor(.primary)
    }

    private func code(_ content: String) -> some View {
        Text(content)
            .font(.footnote.monospaced())
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray5))
            .cornerRadius(6)
    }
}
