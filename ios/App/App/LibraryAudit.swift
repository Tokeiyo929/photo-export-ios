import Foundation
import Photos

/// 图库对账：数出「常规全库抓取」之外的每个可疑桶，与相册 App 底部张数对账，
/// 定位「相册看得见、这里查不到」的照片属于哪一类——先证据后动作。
/// 生态口径（SO 32430410 起的十年悬案，Immich/PhotoSync 等迁移工具同款结论）：
/// - 从电脑同步（iTunes/Finder）进来的照片：PhotoKit 对第三方**完全拿不到**
/// - iCloud 共享相簿：不在全库 fetch 里，要单独按相簿枚举
/// - 已隐藏：默认排除（includeHiddenAssets 打开才看得到）
enum LibraryAudit {

    struct Result {
        var total = 0        // 常规全库（引擎同口径 fetch）
        var undated = 0      // 其中 creationDate 为空（导出序列排最后）
        var hidden = 0       // 已隐藏
        var sharedAlbum = 0  // iCloud 共享相簿资源数
    }

    static func run() -> Result {
        var result = Result()

        // 与引擎完全同口径（PhotoLibraryService.fetchAllAssets 的默认选项）
        let normalResult = PHAsset.fetchAssets(with: PHFetchOptions())
        result.total = normalResult.count

        let withHidden = PHFetchOptions()
        withHidden.includeHiddenAssets = true
        result.hidden = PHAsset.fetchAssets(with: withHidden).count - result.total

        normalResult.enumerateObjects { asset, _, _ in
            if asset.creationDate == nil { result.undated += 1 }
        }

        let shared = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .albumCloudShared,
                                                             options: nil)
        shared.enumerateObjects { collection, _, _ in
            result.sharedAlbum += PHAsset.fetchAssets(in: collection, options: nil).count
        }
        return result
    }

    static func summary(_ r: Result) -> String {
        "常规全库 \(r.total) · 无拍摄时间 \(r.undated) · 已隐藏 \(r.hidden) · iCloud共享相簿 \(r.sharedAlbum)"
    }

    static func describe(_ r: Result) -> String {
        var lines = [summary(r)]
        if r.sharedAlbum > 0 {
            lines.append("有 \(r.sharedAlbum) 项在 iCloud 共享相簿（全库抓取天然不含）→ 用「挑照片补漏导入」接进来")
        }
        if r.hidden > 0 {
            lines.append("有 \(r.hidden) 项已隐藏（默认不导、挑图也选不到）→ 需要的话先在相册里取消隐藏")
        }
        if r.undated > 0 {
            lines.append("有 \(r.undated) 项无拍摄时间（排在导出序列最后，按文件时间兜底归档）")
        }
        if r.sharedAlbum == 0 && r.hidden == 0 {
            lines.append("共享相簿/隐藏都是 0：相册 App 看得见而这里没有的，通常是「从电脑同步」的照片——PhotoKit 对第三方完全拿不到（生态通用限制）→ 用「挑照片补漏导入」逐张接进来；把相册 App 底部的总张数和这里的 \(r.total) 对一下，差值就是同步照片数")
        }
        return lines.joined(separator: "\n")
    }
}
