import Foundation
import Photos

/// 相册访问封装。核心纪律：只用 PHAssetResourceManager.writeData 拿原始字节，
/// 绝不碰 PHImageManager/PHAssetCreationRequest 等会重编码的 API。
enum PhotoLibraryService {

    static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: options)
    }

    /// 挑出该资产要导出的"原始"资源：
    /// - 照片：.photo（原片字节）；RAW+JPEG 的 .alternatePhoto（非 RAW 侧）也保留
    /// - Live Photo：原片 + .pairedVideo 实况视频，成对同名导出
    /// - 视频：.video（原始视频）
    /// 编辑版（.fullSizePhoto/.fullSizeVideo）是渲染产物，会重编码，一律不导。
    static func exportResources(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            var selected = all.filter { $0.type == .photo || $0.type == .alternatePhoto }
            if asset.mediaSubtypes.contains(.photoLive) {
                selected += all.filter { $0.type == .pairedVideo }
            }
            return selected.isEmpty ? all : selected
        case .video:
            let selected = all.filter { $0.type == .video }
            return selected.isEmpty ? all : selected
        default:
            return []
        }
    }

    /// 把原始字节写盘（HEIC 保持 HEIC、MOV 保持 MOV，零转码），同步返回。
    /// iCloud 未下载的原件会按需下载（isNetworkAccessAllowed = true），
    /// onProgress 回调 iCloud 下载比例。后台线程调用，用信号量桥接完成回调。
    static func writeOriginal(resource: PHAssetResource,
                              to url: URL,
                              onProgress: ((Double) -> Void)? = nil) throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if let onProgress {
            options.progressHandler = { fraction in
                onProgress(fraction)
            }
        }
        var boxedError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().writeData(for: resource,
                                                   toFile: url,
                                                   options: options) { error in
            boxedError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let boxedError { throw boxedError }
    }

    /// 全库预计字节数（资源级求和，后台线程调用）。
    static func estimatedLibraryBytes() -> Int64 {
        let fetch = fetchAllAssets()
        var total: Int64 = 0
        fetch.enumerateObjects { asset, _, _ in
            for resource in exportResources(for: asset) {
                total += fileSize(of: resource)
            }
        }
        return total
    }

    /// PHAssetResource 没有公开的 fileSize 属性，用 KVC 读取（社区通行做法），取不到按 0 估算。
    static func fileSize(of resource: PHAssetResource) -> Int64 {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    static func assetInfoKey(for asset: PHAsset) -> String {
        asset.localIdentifier
    }
}
