import Foundation
import CryptoKit

/// 流式 SHA-256 文件哈希。导出链路里每个文件算两次：
/// tmp 写入后一次（证明从相册写出的字节）、移入正式目录后一次（证明移动无误）。
/// PC 端拉取后再算一次与 manifest 比对（证明数据线传输无损）。
enum FileHasher {
    static let chunkSize = 1024 * 1024

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexEncode(Array(hasher.finalize()))
    }

    static func hexEncode(_ bytes: [UInt8]) -> String {
        let map = Array("0123456789abcdef".utf16)
        var chars = [unichar]()
        chars.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            chars.append(map[Int(byte >> 4)])
            chars.append(map[Int(byte & 0x0f)])
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }
}
