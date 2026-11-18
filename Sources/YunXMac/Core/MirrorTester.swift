import Foundation

struct MirrorResult: Identifiable {
    let id = UUID()
    var prefix: String
    var latencyMs: Double?
    var bytesPerSecond: Double?
    var errorText: String?

    var displayHost: String {
        URL(string: prefix)?.host ?? prefix
    }

    var isUsable: Bool { errorText == nil && bytesPerSecond != nil }

    /// 综合评分：延迟占 40%，速度占 60%
    var score: Double {
        guard isUsable, let latencyMs, let bytesPerSecond else { return 0 }
        let latencyScore = 1.0 / max(latencyMs, 1)
        let speedScore = bytesPerSecond
        return latencyScore * 400 + speedScore * 0.6
    }
}

/// GitHub 下载镜像测速：并发实测每个前缀的握手延迟与实际吞吐，挑最快的那个。
enum MirrorTester {

    /// 测速样本：体积不大、长期稳定存在的仓库压缩包
    static let samplePath = "https://github.com/octocat/Hello-World/archive/refs/heads/master.zip"

    static func test(prefixes: [String], timeout: TimeInterval = 6) async -> [MirrorResult] {
        await withTaskGroup(of: MirrorResult.self) { group in
            for prefix in prefixes {
                group.addTask { await testOne(prefix: prefix, timeout: timeout) }
            }
            var results: [MirrorResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.score > $1.score }
        }
    }

    static func testOne(prefix: String, timeout: TimeInterval) async -> MirrorResult {
        let normalized = normalize(prefix)
        var result = MirrorResult(prefix: normalized)

        guard let url = URL(string: normalized + samplePath) else {
            result.errorText = "前缀格式不正确"
            return result
        }

        var request = URLRequest(url: url)
        request.setValue(Prober.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1572863", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout

        let started = Date()
        do {
            let sample = try await SpeedSampler.shared.measure(request, deadline: timeout)
            let elapsed = Date().timeIntervalSince(started)
            result.latencyMs = max(1, sample.timeToFirstByte * 1000)
            if sample.bytes > 0 && elapsed > 0 {
                result.bytesPerSecond = Double(sample.bytes) / max(sample.elapsed, 0.2)
            } else {
                result.errorText = "超时或无响应"
                result.latencyMs = nil
                result.bytesPerSecond = nil
            }
            if let status = sample.status, status >= 400 {
                result.errorText = "HTTP \(status)"
                result.latencyMs = nil
                result.bytesPerSecond = nil
            }
        } catch {
            result.errorText = (error as NSError).localizedDescription
        }
        return result
    }

    /// 统一成 https://host 形式，去掉多余斜杠
    static func normalize(_ prefix: String) -> String {
        var value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if !value.lowercased().hasPrefix("http") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 把原始 GitHub 链接套到镜像前缀上
    static func apply(prefix: String, to url: URL) -> URL {
        let normalized = normalize(prefix)
        guard !normalized.isEmpty else { return url }
        return URL(string: normalized + "/" + url.absoluteString) ?? url
    }
}

/// 在截止时间内采样真实吞吐：收到多少算多少，到点就取消。
///
/// 每次测量用**独立的 URLSession + 独立的委托对象**。
/// 先前版本让多个测量共享一个 session、用 taskIdentifier 索引 continuation，
/// 并发下会出现 continuation 泄漏（任务永久挂起、界面一直停在"测速中"），
/// 改成一对一隔离后从结构上消除了这类共享状态。
final class SpeedSampler {

    static let shared = SpeedSampler()

    struct Sample {
        var bytes: Int
        var elapsed: TimeInterval
        var timeToFirstByte: TimeInterval
        var status: Int?
    }

    func measure(_ request: URLRequest, deadline: TimeInterval) async throws -> Sample {
        let worker = MeasureWorker(request: request, deadline: deadline)
        return try await worker.run()
    }
}

private final class MeasureWorker: NSObject, URLSessionDataDelegate {

    private let request: URLRequest
    private let deadline: TimeInterval

    private var continuation: CheckedContinuation<SpeedSampler.Sample, Error>?
    private let lock = NSLock()
    private var bytes = 0
    private let started = Date()
    private var firstByteAt: Date?
    private var status: Int?
    private var session: URLSession?

    init(request: URLRequest, deadline: TimeInterval) {
        self.request = request
        self.deadline = deadline
        super.init()
    }

    func run() async throws -> SpeedSampler.Sample {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            // delegateQueue 传 nil 时 URLSession 会自建一条串行队列，天然隔离
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = deadline
            configuration.timeoutIntervalForResource = deadline
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in
                self?.finish(with: nil)
            }

            var request = self.request
            if request.value(forHTTPHeaderField: "Range") == nil {
                request.setValue("bytes=0-1572863", forHTTPHeaderField: "Range")
            }
            session.dataTask(with: request).resume()
        }
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let bytes = self.bytes
        let status = self.status
        let firstByteAt = self.firstByteAt
        lock.unlock()

        session?.invalidateAndCancel()
        session = nil

        if let error {
            continuation.resume(throwing: error)
            return
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let ttfb = firstByteAt.map { $0.timeIntervalSince(started) } ?? elapsed
        continuation.resume(returning: SpeedSampler.Sample(
            bytes: bytes, elapsed: elapsed, timeToFirstByte: ttfb, status: status
        ))
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        if firstByteAt == nil { firstByteAt = Date() }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes += data.count
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 到点主动取消不算失败，按采样结果结算
        let isCancelled = (error as? URLError)?.code == .cancelled
        finish(with: isCancelled ? nil : error)
    }
}
