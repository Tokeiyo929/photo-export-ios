import Foundation
import Network
import UIKit

/// 局域网 WiFi 直传服务器：电脑绕开数据线/AFC 直接拉取沙盒 Documents。
/// 背景：iOS 27 真机上 house_arrest/VendDocuments 对重签名 App 服务了错误的容器
/// 视图（按名读永远 OBJECT_NOT_FOUND），数据线拉取通道废了。LocalSend/PhotoSync
/// 等成熟工具同款思路——同一 WiFi 内 App 起 HTTP 服务，电脑按清单拉文件+校验哈希。
/// 路由：
///   GET /                     简单索引页（浏览器手动下载兜底）
///   GET /list                 Documents 全部文件 JSON [{path,size},…]
///   GET /manifest.csv         清单
///   GET /export-log.txt(.old) 工作日志
///   GET /file/<相对路径>      原片文件（1MB 分块流式发送，不整读进内存）
/// 安全边界：无鉴权，仅限同一局域网使用；UI 提示勿在公共 WiFi 开启。
final class WifiServer {

    private let documentsURL: URL
    private let port: UInt16
    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "pe.wifi.state")
    /// 后台时间保护（GCDWebServer 同款）：首个连接进来申请 beginBackgroundTask，
    /// 最后一个连接结束交还——防止传输中切后台/锁屏被系统掐断连接。
    private var activeConnections = 0
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(documentsURL: URL, port: UInt16 = 8765) {
        self.documentsURL = documentsURL
        self.port = port
    }

    /// 本机局域网 IPv4 地址拼出的可访问 URL（多网卡时给全部，用户挑通的那个）
    private(set) var localURLs: [String] = []

    func start() {
        guard listener == nil else { return }
        localURLs = WifiServer.localIPv4s().map { "http://\($0):\(port)" }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let portValue = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: portValue) else {
            ExportLog.write("WIFI server start FAILED port=\(port)（端口被占？）")
            return
        }
        self.listener = listener
        // Bonjour 广播（LocalSend 用 UDP 组播做发现；iOS 原生生态是 Bonjour，
        // PC 端 python zeroconf 一行就接上）——电脑免手打 IP
        let deviceName = UIDevice.current.name
        let build = (Bundle.main.object(forInfoDictionaryKey: "PEBuild") as? String) ?? "?"
        listener.service = NWService(name: deviceName,
                                     type: "_photoexport._tcp.",
                                     txtRecord: ["app": "photo-export", "build": build],
                                     port: NWEndpoint.Port(rawValue: port) ?? 8765)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ExportLog.write("WIFI server ready port=\(self?.port ?? 0) urls=\(self?.localURLs.joined(separator: " ") ?? "")")
            case .failed(let error):
                ExportLog.write("WIFI server failed — \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "pe.wifi.listener"))
    }

    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.endBackgroundTask()
        }
        ExportLog.write("WIFI server stop")
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "pe.wifi.conn")
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connectionClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        connectionOpened()
        receiveRequest(connection, accumulated: Data())
    }

    // MARK: - 后台时间保护

    private func connectionOpened() {
        stateQueue.sync {
            activeConnections += 1
            guard activeConnections == 1 else { return }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WiFi 传图") { [weak self] in
                self?.endBackgroundTask()
            }
            ExportLog.write("WIFI 首个连接：已申请后台时间（防切后台/锁屏掐断传输）")
        }
    }

    private func connectionClosed() {
        stateQueue.sync {
            activeConnections = max(0, activeConnections - 1)
            guard activeConnections == 0 else { return }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundTask != .invalid else { return }
            self.endBackgroundTask()
            ExportLog.write("WIFI 连接清零：交还后台时间")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 收齐请求头（\r\n\r\n 为界）。只处理 GET，不读请求体。
    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                ExportLog.write("WIFI conn recv error — \(error.localizedDescription)")
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 || isComplete { connection.cancel() }
                else { self.receiveRequest(connection, accumulated: buffer) }
                return
            }
            let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            var lines = headerText.split(separator: "\r\n").map(String.init)
            let requestLine = lines.isEmpty ? "" : lines.removeFirst()
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                self.sendText(connection, code: "405 Method Not Allowed", body: "GET only\n")
                return
            }
            self.route(connection, rawPath: String(parts[1]), headers: headers)
        }
    }

    private func route(_ connection: NWConnection, rawPath: String, headers: [String: String]) {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        if path == "/" || path.isEmpty {
            sendText(connection, code: "200 OK", body: Self.indexHTML, contentType: "text/html; charset=utf-8")
        } else if path == "/list" {
            let files = listDocuments()
            guard let data = try? JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]) else {
                sendText(connection, code: "500 Internal Server Error", body: "list failed\n")
                return
            }
            sendHeaders(connection, code: "200 OK",
                        contentType: "application/json",
                        extra: "Content-Length: \(data.count)\r\n",
                        body: data, fileHandle: nil, fileTotal: 0)
        } else if path.hasPrefix("/file/") {
            let relative = String(path.dropFirst("/file/".count))
            serveFile(connection, rawRelative: relative, rangeHeader: headers["range"])
        } else if path.hasPrefix("/export-log") || path == "/manifest.csv" {
            let name = String(path.dropFirst())
            serveFile(connection, rawRelative: name, rangeHeader: headers["range"])
        } else {
            sendText(connection, code: "404 Not Found", body: "not found\n")
        }
    }

    /// 相对路径解析 + 越界防护（拒绝 ".."，必须落在 Documents 内）。
    /// 带 Range 头就回 206 部分内容（GCDWebServer 同款成熟模式）：PC 端大文件断点续传。
    private func serveFile(_ connection: NWConnection, rawRelative: String, rangeHeader: String?) {
        let decoded = rawRelative.removingPercentEncoding ?? rawRelative
        let components = decoded.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("..") else {
            sendText(connection, code: "400 Bad Request", body: "bad path\n")
            return
        }
        var url = documentsURL
        for component in components { url.appendPathComponent(component) }
        let fm = FileManager.default
        guard url.standardizedFileURL.path.hasPrefix(documentsURL.standardizedFileURL.path),
              fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0 else {
            sendText(connection, code: "404 Not Found", body: "not found\n")
            return
        }
        // Range 解析：bytes=N-（断点续传）/ bytes=N-M / bytes=-S（末尾 S 字节）
        var rangeStart: UInt64 = 0
        var isPartial = false
        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            let spec = String(rangeHeader.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            var parsed: UInt64?
            if spec.hasPrefix("-") {
                if let suffix = UInt64(spec.dropFirst()), suffix > 0, suffix <= size { parsed = size - suffix }
            } else {
                let first = spec.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
                if let start = UInt64(first), start < size { parsed = start }
            }
            guard let start = parsed else {
                sendText(connection, code: "416 Range Not Satisfiable", body: "range out of bounds\n")
                return
            }
            rangeStart = start
            isPartial = true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            sendText(connection, code: "500 Internal Server Error", body: "open failed\n")
            return
        }
        let contentType = url.pathExtension.lowercased() == "json" ? "application/json" : "application/octet-stream"
        let bodyLength = size - rangeStart
        var extra = ""
        if isPartial {
            extra += "Content-Range: bytes \(rangeStart)-\(size - 1)/\(size)\r\n"
        }
        extra += "Content-Length: \(bodyLength)\r\n"
        sendHeaders(connection, code: isPartial ? "206 Partial Content" : "200 OK",
                    contentType: contentType,
                    extra: extra,
                    body: Data(), fileHandle: handle, fileTotal: bodyLength, fileOffset: rangeStart)
    }

    // MARK: - 发送（头 + 分块流式文件体）

    private func sendHeaders(_ connection: NWConnection, code: String, contentType: String,
                             extra: String, body: Data, fileHandle: FileHandle?, fileTotal: UInt64,
                             fileOffset: UInt64 = 0) {
        let header = "HTTP/1.1 \(code)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\(extra)\r\n"
        let headerData = Data(header.utf8) + body
        if let fileHandle {
            connection.send(content: headerData, completion: .contentProcessed { error in
                if error != nil { connection.cancel(); try? fileHandle.close(); return }
                self.sendFileChunks(connection, handle: fileHandle, sent: 0,
                                    total: fileTotal, base: fileOffset)
            })
        } else {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendText(_ connection: NWConnection, code: String, body: String,
                          contentType: String = "text/plain; charset=utf-8") {
        sendHeaders(connection, code: code, contentType: contentType,
                    extra: "Content-Length: \(body.utf8.count)\r\n",
                    body: Data(body.utf8), fileHandle: nil, fileTotal: 0)
    }

    /// 1MB 分块流式发送：等上一块被内核收下（contentProcessed）再读下一块，
    /// 天然背压，绝不把大文件整读进内存（这是内存/磁盘压力敏感设备，不能赌）。
    /// base = 文件内绝对起点（Range 续传时是断点偏移），sent 是相对 body 的进度。
    private func sendFileChunks(_ connection: NWConnection, handle: FileHandle, sent: UInt64,
                                total: UInt64, base: UInt64) {
        let chunkSize = 1_048_576
        handle.seek(toFileOffset: base + sent)
        guard let chunk = try? handle.readData(ofLength: chunkSize), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel() // 发完（或文件比 Content-Length 短，让校验哈希兜底）
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil { connection.cancel(); try? handle.close(); return }
            let newSent = sent + UInt64(chunk.count)
            if newSent >= total {
                try? handle.close()
                connection.send(content: Data(), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                self.sendFileChunks(connection, handle: handle, sent: newSent, total: total, base: base)
            }
        })
    }

    // MARK: - 文件枚举

    private func listDocuments() -> [[String: Any]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: documentsURL, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [[String: Any]] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: documentsURL.path + "/", with: "")
            files.append(["path": relative, "size": values.fileSize ?? 0])
        }
        return files
    }

    private static let indexHTML = """
    <!doctype html><meta charset="utf-8"><title>照片无损导出</title>
    <h3>照片无损导出 · WiFi 直传</h3>
    <p>推荐：电脑运行 <code>pull.py --wifi --dest 目标目录</code>（自动发现，同一 WiFi）或 <code>pull.py --wifi http://本机IP:8765 --dest 目标目录</code>，自动按清单拉取并校验哈希、大文件断点续传。</p>
    <ul>
      <li><a href="/manifest.csv">manifest.csv</a>（导出清单）</li>
      <li><a href="/export-log.txt">export-log.txt</a>（工作日志）</li>
      <li><a href="/list">/list</a>（全部文件 JSON）</li>
    </ul>
    <p>原片文件：/file/相对路径（例如 /file/2024/2024-11-24/IMG_1.HEIC）</p>
    """

    // MARK: - 本机局域网 IPv4

    private static func localIPv4s() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, (current.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            // 全部 IPv4 都列出：除家庭 WiFi 外，还要覆盖
            // 「个人热点 + 数据线」的 USB 网卡（172.20.10.x）和链路本地（169.254.x）
            if ip != "127.0.0.1" { addresses.append(ip) }
        }
        // 常见私网段排前面，用户从上往下试
        let rank: (String) -> Int = { ip in
            (ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")) ? 0 : 1
        }
        return addresses.sorted { rank($0) < rank($1) }
    }
}
