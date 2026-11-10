import Foundation

/// 目录名的日期来源。设备侧用 PHAsset.creationDate（系统已解析 EXIF 拍摄时间，
/// 覆盖 HEIC/JPEG/MOV），比 PC 端重新读 EXIF 更准。
enum DateSource: String {
    case creation = "creation"   // 相册拍摄时间
    case fileTime = "filetime"   // 资源文件修改时间
    case undated = "undated"     // 两者皆无 → UNDATED/
}

/// 规划输入：相册里的一条资产（照片/视频/Live Photo）。
/// mediaType: "photo" / "video"
struct AssetInfo {
    let id: String
    let mediaType: String
    let isLive: Bool
    let isFavorite: Bool
    let creationDate: Date?
    let fileDate: Date?
    /// 待导出的原始资源，每个资源对应一个文件（Live Photo 两个：原片 + 实况视频）
    let resources: [ResourceInfo]
}

struct ResourceInfo {
    let fileName: String
    let size: Int64
}

/// 规划输出：一个待写盘的文件
struct PlannedFile {
    let relativePath: String    // "2026/2026-03-15/IMG_1234.HEIC"
    let fileName: String
    let directory: String       // "2026/2026-03-15"
    let dateSource: DateSource
    let fileSize: Int64
}

/// 纯逻辑，无 UIKit/Photos 依赖，进 L1 swiftc 隔离回归。
enum ExportPlanner {

    /// 归档目录："2026/2026-03-15"；拍摄时间 → 文件时间 → UNDATED 逐级回退。
    static func dateDirectory(creationDate: Date?, fileDate: Date?, calendar: Calendar) -> (String, DateSource) {
        if let date = creationDate { return (directoryString(for: date, calendar: calendar), .creation) }
        if let date = fileDate { return (directoryString(for: date, calendar: calendar), .fileTime) }
        return ("UNDATED", .undated)
    }

    static func directoryString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day,
              year > 1900, month >= 1, month <= 12, day >= 1, day <= 31 else { return "UNDATED" }
        return String(format: "%04d/%04d-%02d-%02d", year, year, month, day)
    }

    /// 同一目录内重名（大小写不敏感，iOS 文件系统如此）→ 在扩展名前加 " (1)"。
    /// 用调用方传入的 used 集合跨资产累积，避免同一天多张 burst 同名。
    static func disambiguate(fileName: String, directory: String, used: inout Set<String>) -> String {
        let key = directory.lowercased() + "/" + fileName.lowercased()
        if used.insert(key).inserted { return fileName }
        let base: String
        let ext: String
        if let range = fileName.range(of: ".", options: .backwards), range.lowerBound > fileName.startIndex {
            base = String(fileName[fileName.startIndex..<range.lowerBound])
            ext = String(fileName[range.lowerBound...]) // 含 "."
        } else {
            base = fileName
            ext = ""
        }
        var sequence = 1
        while true {
            let candidate = base + " (\(sequence))" + ext
            let candidateKey = directory.lowercased() + "/" + candidate.lowercased()
            if used.insert(candidateKey).inserted { return candidate }
            sequence += 1
        }
    }

    /// 把资产列表展开成逐文件计划。同目录内跨资产去重。
    static func plan(assets: [AssetInfo], calendar: Calendar) -> [PlannedFile] {
        var planned: [PlannedFile] = []
        var used: Set<String> = []
        for asset in assets {
            let (directory, source) = dateDirectory(creationDate: asset.creationDate,
                                                    fileDate: asset.fileDate,
                                                    calendar: calendar)
            for resource in asset.resources {
                let fileName = disambiguate(fileName: resource.fileName, directory: directory, used: &used)
                planned.append(PlannedFile(relativePath: directory + "/" + fileName,
                                           fileName: fileName,
                                           directory: directory,
                                           dateSource: source,
                                           fileSize: resource.size))
            }
        }
        return planned
    }

    /// 全库预计大小（用于空间预警）。
    static func totalBytes(assets: [AssetInfo]) -> Int64 {
        assets.reduce(0) { sum, asset in sum + asset.resources.reduce(0) { $0 + $1.size } }
    }
}
