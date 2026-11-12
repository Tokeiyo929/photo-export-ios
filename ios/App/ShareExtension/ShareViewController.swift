import UIKit
import UniformTypeIdentifiers

/// 相册分享入口：用户在相册选图 → 分享 → 「无损导出」。
/// 模式对齐 Nextcloud iOS 的 NCFilesExtensionHandler（千万级用户的生产实现）：
/// 优先 loadFileRepresentation 拿系统暂存的**文件**做 copyItem 字节级复制（原名保留），
/// Data 次之，UIImage 渲染图是最后兜底（必然重编码，落 note 如实标注）。
/// 红线：分享扩展内存上限 ~120MB（jetsam 一击即杀、无报告），绝不主动把全尺寸
/// 照片解成位图——这是首版「进度条走完白屏卡死」的根因。
class ShareViewController: UIViewController {

    /// 系统交接文件超时：大视频暂存可能要几十秒，90 秒还没给就是挂了
    private static let timeoutSeconds: DispatchTimeInterval = .seconds(90)

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var received = 0
    private var fellBack = 0
    private var total = 0
    /// 只在主线程读写；超时后到达的回调全部弃单
    private var finished = false
    private let lock = NSLock()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        ingest()
        scheduleTimeout()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.text = "接收中…"
        view.addSubview(spinner)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        spinner.startAnimating()
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = text
        }
    }

    // MARK: - 接收

    private func ingest() {
        SharedGroup.appendLog("EXT open")
        guard let inbox = SharedGroup.inboxDirectory() else {
            SharedGroup.appendLog("EXT no app-group container")
            fail("无法访问共享容器", detail: "重签后 App Group 未生效，文件没有落点。先打开主 App 一次再重试分享。")
            return
        }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.compactMap(\.attachments).flatMap { $0 }

        // 只要文件形态的提供者；图片/视频之外（文字、链接）不接
        let fileLike = providers.filter { provider in
            [UTType.item.identifier, UTType.fileURL.identifier,
             UTType.image.identifier, UTType.movie.identifier]
                .contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
        SharedGroup.appendLog("EXT providers=\(providers.count) fileLike=\(fileLike.count)")
        guard !fileLike.isEmpty else {
            finish()
            return
        }
        total = fileLike.count

        let group = DispatchGroup()
        for provider in fileLike {
            // 挑最可能带文件的标识符（相册分享可能附带 plain-text 的文字说明，不选它）
            let preferred = [UTType.fileURL.identifier, UTType.item.identifier,
                             UTType.image.identifier, UTType.movie.identifier]
            let identifier = provider.registeredTypeIdentifiers.first(where: { preferred.contains($0) })
                ?? provider.registeredTypeIdentifiers.first
                ?? UTType.item.identifier
            SharedGroup.appendLog("EXT load \(identifier)")

            group.enter()
            // 首选：系统暂存文件（原片字节+原名，零解码零内存峰值）
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, error in
                guard let self else { group.leave(); return }
                self.lock.lock()
                defer { self.lock.unlock() }
                defer { group.leave() }
                guard !self.finished else { return }
                if let url {
                    // 暂存文件在回调返回后即被删，必须当场复制
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if self.copyFile(url, provider: provider, into: inbox) {
                        self.received += 1
                    } else {
                        self.fellBack += 1
                    }
                } else {
                    SharedGroup.appendLog("EXT representation FAIL \(error.map { "\($0)" } ?? "?")")
                    self.fallbackLoadItem(provider, identifier: identifier, inbox: inbox, group: group)
                }
                self.setStatus("已接收 \(self.received + self.fellBack)/\(self.total)…")
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish()
        }
    }

    /// 文件形态没拿到 → 退回 loadItem（Data 能写字节；UIImage 只剩渲染图=重编码， jetsam 风险自负且极罕见）
    private func fallbackLoadItem(_ provider: NSItemProvider, identifier: String,
                                  inbox: URL, group: DispatchGroup) {
        group.enter()
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, _ in
            guard let self else { group.leave(); return }
            self.lock.lock()
            defer { self.lock.unlock() }
            defer { group.leave() }
            guard !self.finished else { return }
            SharedGroup.appendLog("EXT item \(type(of: item))")
            switch item {
            case let url as URL:
                if self.copyFile(url, provider: provider, into: inbox) { self.received += 1 } else { self.fellBack += 1 }
            case let data as Data:
                if self.writeData(data, provider: provider, into: inbox, note: nil) { self.received += 1 } else { self.fellBack += 1 }
            case let image as UIImage:
                // 最后兜底：只剩渲染位图 = 必然重编码。写 png 并在队列里如实标注。
                SharedGroup.appendLog("EXT UIImage fallback (jetsam risk)")
                if let data = image.pngData(),
                   self.writeData(data, provider: provider, into: inbox, note: "重编码(仅拿到渲染图)") {
                    self.received += 1
                } else { self.fellBack += 1 }
            default:
                SharedGroup.appendLog("EXT unsupported item")
                self.fellBack += 1
            }
            self.setStatus("已接收 \(self.received + self.fellBack)/\(self.total)…")
        }
    }

    /// 字节级复制（Nextcloud 同款 copyItem）：文件名冲突加序号
    private func copyFile(_ source: URL, provider: NSItemProvider, into inbox: URL) -> Bool {
        let fm = FileManager.default
        // 暂存文件名通常就是 IMG_xxxx.HEIC；没扩展名时用 suggestedName 补
        var name = source.lastPathComponent
        if (name as NSString).pathExtension.isEmpty,
           let suggested = provider.suggestedName, !suggested.isEmpty {
            let ext = source.pathExtension.isEmpty
                ? (provider.registeredTypeIdentifiers.first.flatMap { UTType($0)?.preferredFilenameExtension } ?? "bin")
                : source.pathExtension
            name = "\(suggested).\(ext)"
        }
        var target = inbox.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            target = inbox.appendingPathComponent("\(base)-\(n).\(ext)")
        }
        do {
            try fm.copyItem(at: source, to: target)
            let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? Int64) ?? 0
            SharedGroup.enqueue(file: target.lastPathComponent, note: nil)
            SharedGroup.appendLog(String(format: "EXT copy %@ %lld bytes", target.lastPathComponent, size))
            return true
        } catch {
            SharedGroup.appendLog("EXT copy ERR \(name): \(error)")
            return false
        }
    }

    private func writeData(_ data: Data, provider: NSItemProvider, into inbox: URL, note: String?) -> Bool {
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
            SharedGroup.appendLog(String(format: "EXT write %@ %d bytes", target.lastPathComponent, data.count))
            return true
        } catch {
            SharedGroup.appendLog("EXT write ERR \(suggested): \(error)")
            return false
        }
    }

    // MARK: - 收尾

    private func finish() {
        guard !finished else { return }
        finished = true
        SharedGroup.appendLog("EXT done received=\(received) fellBack=\(fellBack)")
        spinner.stopAnimating()
        if received > 0 {
            let alert = UIAlertController(title: "已接收 \(received) 个文件",
                                          message: fellBack > 0 ? "其中 \(fellBack) 个走了降级通道（详见主 App 记录）" : "原片字节已保存，打开主 App 完成登记",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.done() })
            present(alert, animated: true)
        } else {
            fail("没有收到文件", detail: nil)
        }
    }

    private func fail(_ title: String, detail: String?) {
        spinner.stopAnimating()
        setStatus(title)
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.done() })
        present(alert, animated: true)
    }

    private func scheduleTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            guard let self, !self.finished else { return }
            SharedGroup.appendLog("EXT timeout 90s received=\(self.received) fellBack=\(self.fellBack)")
            self.fail("接收超时", detail: "系统迟迟没有交出文件（大视频暂存或系统繁忙）。可稍后重试，或改用主 App 全库导出。")
        }
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
