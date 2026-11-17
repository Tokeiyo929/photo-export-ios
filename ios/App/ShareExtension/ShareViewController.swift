import UIKit
import UniformTypeIdentifiers
import ObjectiveC

/// 相册分享入口：用户在相册选图 → 分享 → 「无损导出」。
/// 模式对齐 Nextcloud iOS 的 NCFilesExtensionHandler（千万级用户的生产实现）：
/// 优先 loadFileRepresentation 拿系统暂存的**文件**做 copyItem 字节级复制（原名保留），
/// Data 次之，UIImage 渲染图是最后兜底（必然重编码，落 note 如实标注）。
/// 红线：分享扩展内存上限 ~120MB（jetsam 一击即杀、无报告），绝不主动把全尺寸
/// 照片解成位图——这是首版「进度条走完白屏卡死」的根因。
///
/// 大批量（257 张实测）：并发限制在 4 个，顺序交接、逐件落盘记账；
/// **不再在 90 秒后弃单**——之前超时把 finished 置 true，息屏挂起期间排队到达的
/// 回调全被丢掉，257 张只登记 145 张就是这么来的。现在超时只提示不弃单。
class ShareViewController: UIViewController {

    /// 同时向系统要文件的并发数：257 个一起要会被系统节流/超时，
    /// 4 个刚好贴合 iCloud 原片下载的并发度
    private static let maxConcurrent = 4

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var received = 0
    private var fellBack = 0
    private var total = 0
    private var completed = 0
    /// 只在主线程读写；收尾后到达的回调弃单
    private var finished = false
    /// open 回调是否已处理（成功/失败/超时只收尾一次）
    private var openResolved = false
    private var inboxURL: URL?
    private var pendingJobs: [(provider: NSItemProvider, identifier: String)] = []
    private var inFlight = 0
    private var startedAt = Date()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        keepDisplayAwake()
        ingest()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.text = "接收中…请保持屏幕亮着"
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

    /// 尽力阻止自动锁屏：扩展进程不保证有 UIApplication（宿主是相册），
    /// 用 ObjC 运行时拿 sharedApplication 再 KVC 置 idleTimerDisabled，结果落日志；
    /// 哪怕系统不认，也只是无效，不影响接收。
    private func keepDisplayAwake() {
        let sel = NSSelectorFromString("sharedApplication")
        guard let cls = NSClassFromString("UIApplication"),
              let method = class_getClassMethod(cls, sel) else {
            SharedGroup.appendLog("EXT idle-timer: no UIApplication class")
            return
        }
        typealias SharedAppFn = @convention(c) () -> AnyObject
        let fn = unsafeBitCast(method_getImplementation(method), to: SharedAppFn.self)
        guard let app = fn() as? NSObject else {
            SharedGroup.appendLog("EXT idle-timer: no shared app instance")
            return
        }
        app.setValue(true, forKey: "idleTimerDisabled")
        let readback = (app.value(forKey: "idleTimerDisabled") as? Bool) ?? false
        SharedGroup.appendLog("EXT idle-timer disabled=\(readback)")
    }

    // MARK: - 接收

    private func ingest() {
        SharedGroup.appendLog("EXT open")
        guard let inbox = SharedGroup.inboxDirectory() else {
            SharedGroup.appendLog("EXT no app-group container \(SharedGroup.lastProbeDescription)")
            // 弹窗直接携带探测详情：用户截个图，组名真值/试过的候选就全在手里
            fail("无法访问共享容器", detail: "重签后 App Group 未生效，文件没有落点。探测详情：\(SharedGroup.lastProbeDescription)。\n\n临时可用：返回分享面板，点 App 行里的「照片无损导出」图标（直投通道，不依赖 App Group）。")
            return
        }
        inboxURL = inbox
        // 成功也要记容器真值：主 App 看到 0 项时，靠这条区分「扩展写进了另一个容器」
        SharedGroup.appendLog("EXT container \(SharedGroup.lastProbeDescription)")
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
        startedAt = Date()
        SharedGroup.appendLog("EXT batch total=\(total) concurrency=\(Self.maxConcurrent)")
        pendingJobs = fileLike.map { ($0, preferredIdentifier($0)) }
        pump()
        scheduleSlowHint()
    }

    /// 挑最可能带文件的标识符（相册分享可能附带 plain-text 的文字说明，不选它）
    private func preferredIdentifier(_ provider: NSItemProvider) -> String {
        let preferred = [UTType.fileURL.identifier, UTType.item.identifier,
                         UTType.image.identifier, UTType.movie.identifier]
        return provider.registeredTypeIdentifiers.first(where: { preferred.contains($0) })
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.item.identifier
    }

    /// 主线程调度：最多 4 个在途，全部收完才收尾
    private func pump() {
        guard !finished else { return }
        while inFlight < Self.maxConcurrent, !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            inFlight += 1
            load(job.provider, identifier: job.identifier)
        }
        if pendingJobs.isEmpty && inFlight == 0 {
            finish()
        }
    }

    private func load(_ provider: NSItemProvider, identifier: String) {
        SharedGroup.appendLog("EXT load \(identifier)")
        // 首选：系统暂存文件（原片字节+原名，零解码零内存峰值）
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, error in
            guard let self else { return }
            if let url {
                // 暂存文件在回调返回后即被删，必须当场复制
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let ok = self.copyFile(url, provider: provider, into: self.inboxURL ?? url)
                DispatchQueue.main.async { self.providerDone(success: ok) }
            } else {
                SharedGroup.appendLog("EXT representation FAIL \(error.map { "\($0)" } ?? "?")")
                self.fallbackLoadItem(provider, identifier: identifier)
            }
        }
    }

    /// 文件形态没拿到 → 退回 loadItem（Data 能写字节；UIImage 只剩渲染图=重编码， jetsam 风险自负且极罕见）
    private func fallbackLoadItem(_ provider: NSItemProvider, identifier: String) {
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, _ in
            guard let self, let inbox = self.inboxURL else { return }
            SharedGroup.appendLog("EXT item \(type(of: item))")
            var success = false
            switch item {
            case let url as URL:
                success = self.copyFile(url, provider: provider, into: inbox)
            case let data as Data:
                success = self.writeData(data, provider: provider, into: inbox, note: nil)
            case let image as UIImage:
                // 最后兜底：只剩渲染位图 = 必然重编码。写 png 并在队列里如实标注。
                SharedGroup.appendLog("EXT UIImage fallback (jetsam risk)")
                if let data = image.pngData() {
                    success = self.writeData(data, provider: provider, into: inbox, note: "重编码(仅拿到渲染图)")
                }
            default:
                SharedGroup.appendLog("EXT unsupported item")
            }
            DispatchQueue.main.async { self.providerDone(success: success) }
        }
    }

    /// 单件交接结束（主线程）：计数、进度、继续派活
    private func providerDone(success: Bool) {
        guard !finished else { return }
        inFlight -= 1
        completed += 1
        if success { received += 1 } else { fellBack += 1 }
        setStatus("已接收 \(received + fellBack)/\(total)…请保持屏幕亮着")
        if completed % 20 == 0 || completed == total {
            let elapsed = Date().timeIntervalSince(startedAt)
            SharedGroup.appendLog(String(format: "EXT progress %d/%d %.1fs", completed, total, elapsed))
        }
        pump()
    }

    /// 大批量慢提示：**只提示不弃单**——之前 90s 超时置 finished 后，
    /// 息屏挂起期间排队到达的文件回调全被丢掉（257 张只登记 145 张的根因）
    private func scheduleSlowHint() {
        let seconds = max(120, total * 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            guard let self, !self.finished, self.completed < self.total else { return }
            SharedGroup.appendLog("EXT slow \(self.completed)/\(self.total) after \(seconds)s")
            self.setStatus("已接收 \(self.received + self.fellBack)/\(self.total)…\n交接较慢，息屏会暂停，请保持屏幕亮着")
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
        setStatus("已接收 \(received + fellBack)/\(total)")
        if received > 0 {
            // 分享完直接拉起主 App：extensionContext.open 在分享扩展上不是官方保证
            // （Apple 论坛 27295：Share Extension 不允许 open URL），先尽力试——
            // 成功用户直接进 App 自动登记；被系统拒了才退回弹窗指路。
            openHostApp(fallback: { [weak self] in
                guard let self else { return }
                let container = SharedGroup.resolvedGroupName.isEmpty ? "未定位" : SharedGroup.resolvedGroupName
                let alert = UIAlertController(
                    title: "已接收 \(self.received) 个文件",
                    message: (self.fellBack > 0 ? "其中 \(self.fellBack) 个走了降级通道（详见主 App 记录）。" : "")
                        + "原片字节已保存（容器 \(container)），回桌面打开主 App 完成登记。\n\n"
                        + "想一步到位：下次分享时点 App 行里的「照片无损导出」图标（直投通道，系统会直接打开 App）。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.done() })
                self.present(alert, animated: true)
            })
        } else {
            fail("没有收到文件", detail: nil)
        }
    }

    /// 尽力拉起主 App（photoexport://shared）：主 App 收到即扫收件箱登记。
    /// 2 秒没回调也要收尾（个别系统版本 open 回调不来，否则扩展界面挂死）。
    private func openHostApp(fallback: @escaping () -> Void) {
        guard let url = URL(string: "photoexport://shared") else { fallback(); return }
        openResolved = false
        extensionContext?.open(url) { [weak self] opened in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.openResolved else { return }
                self.openResolved = true
                if opened {
                    SharedGroup.appendLog("EXT opened host app")
                    self.done()
                } else {
                    SharedGroup.appendLog("EXT open host app refused")
                    fallback()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.openResolved else { return }
            self.openResolved = true
            SharedGroup.appendLog("EXT open host app no callback")
            fallback()
        }
    }

    private func fail(_ title: String, detail: String?) {
        spinner.stopAnimating()
        setStatus(title)
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.done() })
        present(alert, animated: true)
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
