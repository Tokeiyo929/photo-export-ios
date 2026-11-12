import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 挑图补漏：相册 App 看得见而 PhotoKit 全库抓取拿不到的照片（从电脑同步的、
/// iCloud 共享相簿的），用 PHPicker 逐张挑出来补进导出链路——PHPicker 在相册
/// 进程里渲染用户的完整图库视图（成熟迁移工具同款兜底，SO 32430410 的标准出路），
/// 系统把选中文件的字节暂存递过来，走与分享导入完全相同的落位+清单登记
/// （同一条哈希证明链，PC 端零改动）。
/// 已知边界：Live Photo 经 picker 只拿到静态半（pairedVideo 走 bundle 表示，
/// 暂不拆包）；隐藏照片 picker 里也看不见。
enum PickerIn {

    /// PHPicker 选完后的接收会话：串行落位（重名消歧是顺序敏感的），完成回主线程
    final class Session {
        private let documentsURL: URL
        private let manifestURL: URL
        private let progress: (Int, Int) -> Void
        private let completion: (Int, Int, Int) -> Void
        private var total = 0
        private var known: Set<String> = []
        private var used: Set<String> = []
        private var pending: [ManifestRow] = []
        private var ok = 0
        private var skipped = 0
        private var failed = 0
        private var done = 0
        private let iso = ISO8601DateFormatter()
        private let serial = DispatchQueue(label: "photoexport.picker-in", qos: .utility)
        private let group = DispatchGroup()

        init(providers: [NSItemProvider], documentsURL: URL, manifestURL: URL,
             progress: @escaping (Int, Int) -> Void,
             completion: @escaping (Int, Int, Int) -> Void) {
            self.documentsURL = documentsURL
            self.manifestURL = manifestURL
            self.progress = progress
            self.completion = completion
            total = providers.count
            ExportLog.write("PICKER begin \(providers.count)")
            serial.async { [self] in
                let sets = SharedIn.guardSets(documentsURL: documentsURL, manifestURL: manifestURL)
                known = sets.known
                used = sets.used
            }
            for provider in providers {
                group.enter()
                load(provider)
            }
            group.notify(queue: serial) { [self] in
                finish()
            }
        }

        private func load(_ provider: NSItemProvider) {
            let identifier = [UTType.image.identifier, UTType.movie.identifier,
                              UTType.item.identifier, UTType.fileURL.identifier]
                .first { provider.hasItemConformingToTypeIdentifier($0) } ?? UTType.item.identifier
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { [self] url, error in
                serial.async { [self] in
                    defer {
                        done += 1
                        let finished = done
                        let totalNow = total
                        DispatchQueue.main.async { [progress] in
                            progress(finished, totalNow)
                        }
                        group.leave()
                    }
                    guard let url else {
                        failed += 1
                        ExportLog.write("PICKER load FAIL \(error.map { "\($0)" } ?? "?")")
                        return
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        if let row = try SharedIn.importFile(url, documentsURL: documentsURL,
                                                             inboxFile: url.lastPathComponent,
                                                             known: &known, used: &used,
                                                             note: "", iso: iso,
                                                             fallbackNote: "PHPicker补漏导入") {
                            pending.append(row)
                            ok += 1
                        } else {
                            skipped += 1 // 重复内容：这张已经导过
                        }
                    } catch {
                        failed += 1
                        ExportLog.write("PICKER import FAIL \(url.lastPathComponent): \(error)")
                    }
                }
            }
        }

        private func finish() {
            if !pending.isEmpty {
                try? ManifestStore.append(url: manifestURL, rows: pending)
            }
            ExportLog.write("PICKER ok=\(ok) skip=\(skipped) fail=\(failed)")
            let result = (ok, skipped, failed)
            DispatchQueue.main.async { [completion] in
                completion(result.0, result.1, result.2)
            }
        }
    }
}

/// PHPicker 的 SwiftUI 壳（多选，图+视频）。photoLibrary 不传 = 不吃相册授权模式限制。
struct PickerSheet: UIViewControllerRepresentable {
    var onFinish: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([NSItemProvider]) -> Void

        init(onFinish: @escaping ([NSItemProvider]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onFinish(results.map(\.itemProvider))
        }
    }
}
