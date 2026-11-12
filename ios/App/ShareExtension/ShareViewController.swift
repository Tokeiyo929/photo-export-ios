import UIKit
import UniformTypeIdentifiers

/// 相册分享入口：用户在相册选图 → 分享 → 「无损导出」。
/// 模式对齐 Nextcloud iOS 的 NCFilesExtensionHandler（千万级用户的生产实现）：
/// 优先从 item provider 拿 **file URL** 做 copyItem 字节级复制（原名保留），
/// UIImage/Data 是重编码兜底（无损红线，落到 note 里标注，绝不冒充原片）。
/// 文件落到 App Group 的 ShareInbox/，主 App 下次启动搬进 Documents 并登记清单。
class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        ingest()
    }

    private func ingest() {
        let groupDir = SharedGroup.inboxDirectory()
        guard let inbox = groupDir else {
            self.done()
            return
        }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.compactMap(\.attachments).flatMap { $0 }

        var imported = 0
        var fellBack = 0
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
            // 只要文件形态的提供者；图片/视频之外（文本、链接）不接
            let isFileLike = provider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            guard isFileLike else { continue }

            group.enter()
            provider.loadItem(forTypeIdentifier: provider.registeredTypeIdentifiers.first
                                ?? UTType.item.identifier,
                              options: nil) { item, _ in
                lock.lock()
                defer { lock.unlock() }
                switch item {
                case let url as URL:
                    // 成熟路径：系统递来的就是文件（原片字节+原名），直接复制
                    if self.copyFile(url, into: inbox) { imported += 1 } else { fellBack += 1 }
                case let data as Data:
                    // 兜底：字节能拿就拿（文件名可能丢，按建议名/时间戳补）
                    if self.writeData(data, provider: provider, into: inbox) { imported += 1 } else { fellBack += 1 }
                case let image as UIImage:
                    // 最后兜底：只剩渲染位图 = 必然重编码。写 png 并在队列里如实标注。
                    if let data = image.pngData(), self.writeData(data, provider: provider, into: inbox, note: "重编码(仅拿到渲染图)") {
                        imported += 1
                    } else { fellBack += 1 }
                default:
                    fellBack += 1
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let context = self?.extensionContext {
                if imported > 0 {
                    let alert = UIAlertController(title: "已接收 \(imported) 个文件",
                                                  message: fellBack > 0 ? "其中 \(fellBack) 个走了降级通道（详见主 App 记录）" : "原片字节已保存，打开主 App 完成登记",
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in self?.done() })
                    self?.present(alert, animated: true)
                } else {
                    let alert = UIAlertController(title: "没有收到文件", message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default) { _ in self?.done() })
                    self?.present(alert, animated: true)
                }
            }
        }
    }

    /// 字节级复制（Nextcloud 同款 copyItem）：文件名冲突加序号
    private func copyFile(_ source: URL, into inbox: URL) -> Bool {
        let fm = FileManager.default
        var target = inbox.appendingPathComponent(source.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            let base = source.deletingPathExtension().lastPathComponent
            target = inbox.appendingPathComponent("\(base)-\(n).\(source.pathExtension)")
        }
        do {
            try fm.copyItem(at: source, to: target)
            SharedGroup.enqueue(file: target.lastPathComponent, note: nil)
            return true
        } catch {
            return false
        }
    }

    private func writeData(_ data: Data, provider: NSItemProvider, into inbox: URL, note: String? = nil) -> Bool {
        let suggested = provider.suggestedName ?? "shared-\(Int(Date().timeIntervalSince1970))"
        let ext = provider.registeredTypeIdentifiers.first.flatMap { UTType($0)?.preferredFilenameExtension } ?? "bin"
        var target = inbox.appendingPathComponent("\(suggested).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = inbox.appendingPathComponent("\(suggested)-\(n).\(ext)")
        }
        do {
            try data.write(to: target, options: [.atomic])
            SharedGroup.enqueue(file: target.lastPathComponent, note: note)
            return true
        } catch {
            return false
        }
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
