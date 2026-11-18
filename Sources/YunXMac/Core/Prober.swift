import Foundation

struct ProbeResult {
    var finalURL: URL
    var totalSize: Int64          // -1 表示服务器没给长度
    var supportsRange: Bool
    var suggestedFileName: String
    var etag: String?
    var lastModified: String?
    var contentType: String?
}

enum ProbeError: LocalizedError {
    case badStatus(Int)
    case notHTTP
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            if code == 404 { return "资源不存在（HTTP 404）" }
            if code == 403 { return "服务器拒绝访问（HTTP 403），可能需要登录或链接已过期" }
            if code >= 500 { return "服务器错误（HTTP \(code)）" }
            return "请求失败（HTTP \(code)）"
        case .notHTTP:
            return "返回的不是 HTTP 响应"
        case .blocked(let message):
            return message
        }
    }
}

/// 只取响应头，不落盘。用 Range: bytes=0-0 试探服务器是否支持分片。
enum Prober {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 YunX-Mac/1.0"

    static func probe(url: URL, headers: [String: String] = [:]) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (response, data) = try await HeaderSniffer.shared.sniff(request)

        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }

        switch http.statusCode {
        case 200, 206:
            break
        default:
            throw ProbeError.badStatus(http.statusCode)
        }

        var total: Int64 = -1
        var supportsRange = false

        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = parseContentRange(contentRange) {
            total = parsed.total
            supportsRange = parsed.total > 0
        } else {
            let length = http.expectedContentLength
            total = length > 0 ? length : -1
            // 服务器忽略了 Range，说明不支持分片（或长度未知）
            if let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased(),
               acceptRanges == "bytes", total > 0 {
                supportsRange = true
            }
        }

        // 0 字节资源直接判失败，避免创建空任务
        if total == 0 { throw ProbeError.blocked("这是一个空文件（0 字节）") }
        _ = data

        let fileName = resolveFileName(
            contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
            url: http.url ?? url,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )

        return ProbeResult(
            finalURL: http.url ?? url,
            totalSize: total,
            supportsRange: supportsRange,
            suggestedFileName: fileName,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    // MARK: Content-Range

    /// 解析 "bytes 0-0/123456" 或 "bytes 0-0/*"
    static func parseContentRange(_ value: String) -> (total: Int64, start: Int64, end: Int64)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0]
        let totalPart = parts[1]

        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        let total = Int64(totalPart.trimmingCharacters(in: .whitespaces)) ?? -1
        return (total, start, end)
    }

    // MARK: 文件名

    static func resolveFileName(contentDisposition: String?, url: URL, contentType: String?) -> String {
        if let disposition = contentDisposition, let name = fileNameFromDisposition(disposition) {
            return sanitize(name)
        }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/", last.contains(".") {
            return sanitize(last)
        }
        let fallback = "下载文件"
        if let ext = extensionForContentType(contentType) {
            return fallback + ext
        }
        return fallback
    }

    /// 支持 filename*=UTF-8''xxx 与 filename="xxx"
    static func fileNameFromDisposition(_ value: String) -> String? {
        let lower = value.lowercased()

        if let range = lower.range(of: "filename*=") {
            let tail = value[range.upperBound...]
            let piece = tail.split(separator: ";", maxSplits: 1).first.map(String.init) ?? String(tail)
            // 形如 UTF-8''%E4%B8%AD%E6%96%87.pdf
            if let encoded = piece.split(separator: "'", maxSplits: 2).last {
                let decoded = String(encoded).removingPercentEncoding
                if let decoded, !decoded.isEmpty { return decoded }
            }
        }

        if let range = value.range(of: "filename=", options: .caseInsensitive) {
            var tail = String(value[range.upperBound...])
            tail = tail.split(separator: ";", maxSplits: 1).first.map(String.init) ?? tail
            tail = tail.trimmingCharacters(in: .whitespaces)
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !tail.isEmpty { return tail.removingPercentEncoding ?? tail }
        }
        return nil
    }

    /// 去掉路径分隔符与非法字符，避免写出目录
    static func sanitize(_ name: String) -> String {
        var value = name
        value = value.replacingOccurrences(of: "/", with: "_")
        value = value.replacingOccurrences(of: ":", with: "_")
        value = value.replacingOccurrences(of: "\u{0}", with: "")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." { return "下载文件" }
        if value.count > 180 { value = String(value.prefix(180)) }
        return value
    }

    static func extensionForContentType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let base = contentType.split(separator: ";").first.map(String.init)?.lowercased() ?? ""
        let map: [String: String] = [
            "video/mp4": ".mp4", "video/quicktime": ".mov", "video/x-matroska": ".mkv",
            "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/flac": ".flac",
            "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif",
            "image/webp": ".webp", "application/pdf": ".pdf",
            "application/zip": ".zip", "application/x-7z-compressed": ".7z",
            "text/plain": ".txt", "application/json": ".json"
        ]
        return map[base]
    }
}

/// 只读响应头就取消的探针。避免"服务器不支持 Range 时把整个文件读进内存"。
final class HeaderSniffer: NSObject, URLSessionDataDelegate {

    static let shared = HeaderSniffer()

    private var continuations: [Int: CheckedContinuation<(URLResponse, Data), Error>] = [:]
    private var dataByTask: [Int: Data] = [:]
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "yunx.probe"
        return URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
    }()

    func sniff(_ request: URLRequest) async throws -> (URLResponse, Data) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            dataByTask[task.taskIdentifier] = Data()
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 3xx 交给 URLSession 自己跟随，不要在这里就收工
        if let http = response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            completionHandler(.allow)
            return
        }

        // 头已经拿到了，立刻收工
        completionHandler(.cancel)

        lock.lock()
        let continuation = continuations.removeValue(forKey: dataTask.taskIdentifier)
        let data = dataByTask.removeValue(forKey: dataTask.taskIdentifier) ?? Data()
        lock.unlock()

        continuation?.resume(returning: (response, data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        _ = dataByTask.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        // 正常路径已经在 didReceive response 里 resume 过，这里只处理握手阶段的失败
        if let continuation, let error {
            continuation.resume(throwing: error)
        } else if let continuation {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
