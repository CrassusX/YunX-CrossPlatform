import Foundation

/// 单文件的分片并发下载器。
///
/// 设计要点：
/// - **一个写线程独占所有写盘操作**：网络回调只把数据塞进缓冲队列，写盘、限速、
///   重试调度都在写线程里串行完成。这样既保证顺序（不会错位写），又把背压做干净了。
/// - **背压**：缓冲超过高水位就 suspend 数据任务，降到低水位再 resume，
///   避免限速时把整个文件堆进内存。
/// - **可恢复**：每个分片的 `received` 就是已落盘字节数，暂停时直接持久化，
///   恢复时按 `nextOffset` 重新发 Range 请求。
final class SegmentedDownloader: NSObject, URLSessionDataDelegate {

    struct Spec {
        var url: URL
        var headers: [String: String] = [:]
        var tempURL: URL
        var totalSize: Int64
        var supportsRange: Bool
        var segments: [SegmentState]
    }

    // MARK: 对外回调

    var onProgress: ((Int64, Int64) -> Void)?
    var onCompletion: ((Error?) -> Void)?

    // MARK: 内部状态

    private let spec: Spec
    private let condition = NSCondition()
    /// 回调一律走这条队列，绝不在写线程上执行外部代码，
    /// 否则调用方在 onProgress 里调 pause() 会等待自己而死锁
    private let callbackQueue = DispatchQueue(label: "yunx.download.callback")
    private let isStreamMode: Bool

    private var segments: [SegmentState]
    private var segmentDone: Set<Int> = []
    private var buffers: [Int: [Data]] = [:]
    private var writeOffset: [Int: Int64] = [:]
    private var activeTasks: [Int: URLSessionDataTask] = [:]
    private var taskSegment: [Int: Int] = [:]
    private var taskStart: [Int: Int64] = [:]
    private var attempts: [Int: Int] = [:]
    private var bufferedBytes = 0
    private var stopping = false
    private var settled = false
    private var failure: Error?
    private var fileHandle: FileHandle?
    private var session: URLSession!
    private var writer: Thread?
    private var writerAlive = false
    private var lastReport: Double = 0
    private var suspendedTasks = Set<Int>()
    /// 响应头一看就不该要的请求（5xx / 429 等），标记后丢弃它的 body，
    /// 否则错误页的 HTML 会被当成文件内容写进分片，白白污染进度
    private var discardedTasks = Set<Int>()
    /// 最后一次收到任意字节的时间，用于判断连接是否僵死
    private var lastDataAt = Date()
    /// 每个分片最早可以重连的时刻。
    /// 退避不能靠在线程里 sleep 实现——写线程只有一个，一个分片睡 8 秒，
    /// 其余七个分片就全都跟着干等，并发直接退化成串行。
    private var retryAfter: [Int: Date] = [:]
    private var cursor = 0

    private let highWater = 32 * 1024 * 1024
    private let lowWater = 8 * 1024 * 1024
    /// 单个分片允许的重连次数。
    /// 一次网络抖动会同时打断所有分片，所以这个值要按最坏情况给足：
    /// 6 次在弱网下几分钟就耗光了，30 次才够撑过一次典型的断网恢复。
    private let maxAttempts = 30
    /// 连接活着但长时间一个字节都不来，就判定僵死并主动断开重连。
    /// 百度的 dlink 很常见这种"不报错也不吐数据"的挂死状态。
    private let stallTimeout: TimeInterval = 150

    // MARK: 初始化

    init(spec: Spec) {
        self.spec = spec
        self.isStreamMode = spec.totalSize <= 0
        if spec.supportsRange {
            self.segments = spec.segments
        } else {
            // 服务器不支持 Range：只能单连接从头下，续传等于重下
            self.segments = [SegmentState(start: 0,
                                          end: max(0, spec.totalSize - 1),
                                          received: 0)]
        }
        for (index, segment) in self.segments.enumerated() {
            writeOffset[index] = segment.nextOffset
            if segment.isDone && spec.totalSize > 0 { segmentDone.insert(index) }
        }
        super.init()
    }

    // MARK: 生命周期

    func start() {
        do {
            try prepareFile()
        } catch {
            settle(with: error)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600 * 12
        config.httpMaximumConnectionsPerHost = max(4, segments.count)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "yunx.download.delegate"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)

        condition.lock()
        writerAlive = true
        condition.unlock()

        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.name = "yunx.download.writer"
        thread.qualityOfService = .utility
        writer = thread
        thread.start()
    }

    /// 暂停：停写线程 → 取消所有任务 → 返回已落盘的分片状态
    @discardableResult
    func pause() -> [SegmentState] {
        condition.lock()
        if settled {
            let snapshot = segments
            condition.unlock()
            return snapshot
        }
        stopping = true
        condition.broadcast()
        while writerAlive {
            condition.wait(until: Date().addingTimeInterval(1))
        }
        let snapshot = segments
        condition.unlock()

        session?.invalidateAndCancel()
        settle(with: nil)
        return snapshot
    }

    func snapshotSegments() -> [SegmentState] {
        condition.lock(); defer { condition.unlock() }
        return segments
    }

    func currentReceived() -> Int64 {
        condition.lock(); defer { condition.unlock() }
        return segments.reduce(0) { $0 + $1.received }
    }

    /// 供限速器轮询用：暂停时尽快放弃等待
    var isStopping: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopping || settled
    }

    // MARK: 文件准备

    private func prepareFile() throws {
        let fm = FileManager.default
        let directory = spec.tempURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: spec.tempURL.path) {
            guard fm.createFile(atPath: spec.tempURL.path, contents: nil) else {
                throw NSError(domain: "YunX", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件：\(spec.tempURL.path)"])
            }
        }
        let handle = try FileHandle(forWritingTo: spec.tempURL)
        if spec.totalSize > 0 {
            // 稀疏文件预分配，避免边下边扩容产生碎片
            try handle.truncate(atOffset: UInt64(spec.totalSize))
        }
        fileHandle = handle
    }

    // MARK: 写线程（同时充当调度器）

    private func writerLoop() {
        while true {
            condition.lock()

            if stopping {
                closeFileLocked()
                writerAlive = false
                condition.broadcast()
                condition.unlock()
                return
            }

            if let error = failure {
                closeFileLocked()
                writerAlive = false
                condition.broadcast()
                condition.unlock()
                settle(with: error)
                return
            }

            if segmentDone.count == segments.count {
                closeFileLocked()
                writerAlive = false
                condition.broadcast()
                condition.unlock()
                settle(with: nil)
                return
            }

            // 1) 该写盘吗（保证同一分片内顺序）
            if let index = firstIndexWithBufferedData() {
                // 合并小包再写：既减少系统调用，也让限速的时间片更长、更稳
                var chunk = buffers[index]!.removeFirst()
                bufferedBytes -= chunk.count
                while chunk.count < 512 * 1024, let more = buffers[index]?.first {
                    buffers[index]!.removeFirst()
                    bufferedBytes -= more.count
                    chunk.append(more)
                }
                if buffers[index]?.isEmpty == true { buffers[index] = nil }
                let offset = writeOffset[index] ?? segments[index].start

                let room = segments[index].end - offset + 1
                let payload: Data = room > 0 && Int64(chunk.count) > room ? chunk.prefix(Int(room)) : chunk
                writeOffset[index] = offset + Int64(payload.count)
                segments[index].received = writeOffset[index]! - segments[index].start

                let shouldResume = bufferedBytes < lowWater
                let toResume = shouldResume ? Array(suspendedTasks) : []
                if shouldResume { suspendedTasks.removeAll() }

                let isDone = !isStreamMode && segments[index].received >= segments[index].length
                if isDone { segmentDone.insert(index) }

                condition.unlock()

                do {
                    Throttle.shared.acquire(payload.count, isCancelled: { [weak self] in
                        self?.isStopping ?? true
                    })
                    try fileHandle?.seek(toOffset: UInt64(offset))
                    try fileHandle?.write(contentsOf: payload)
                } catch {
                    condition.lock()
                    failure = error
                    condition.broadcast()
                    condition.unlock()
                    continue
                }

                for id in toResume {
                    condition.lock()
                    let task = activeTasks.values.first { $0.taskIdentifier == id }
                    condition.unlock()
                    task?.resume()
                }

                reportProgress()
                continue
            }

            // 2) 该起新任务吗
            let now = Date()
            if let index = nextSegmentNeedingTask(now: now) {
                let attempt = (attempts[index] ?? 0) + 1
                attempts[index] = attempt
                if attempt > maxAttempts {
                    failure = NSError(domain: "YunX", code: 2, userInfo: [
                        NSLocalizedDescriptionKey:
                            "连接连续中断 \(maxAttempts) 次，已暂停这个分片的重连。"
                            + "网络恢复后点「继续」会从这里接着下。"
                    ])
                    condition.broadcast()
                    condition.unlock()
                    continue
                }

                let start = writeOffset[index] ?? segments[index].start
                segments[index].received = start - segments[index].start
                let task = makeTask(for: index, from: start)
                activeTasks[index] = task
                taskSegment[task.taskIdentifier] = index
                taskStart[task.taskIdentifier] = start
                retryAfter.removeValue(forKey: index)
                condition.unlock()

                task.resume()
                continue
            }

            // 3) 僵死连接：任务还在、也没有被背压挂起，但很久没有字节进来。
            //    主动断开，让上面的分支重新建连（计入重试次数）。
            if !activeTasks.isEmpty,
               suspendedTasks.isEmpty,
               Date().timeIntervalSince(lastDataAt) > stallTimeout {
                let stuck = Array(activeTasks.values)
                lastDataAt = Date()
                condition.unlock()
                for task in stuck { task.cancel() }
                continue
            }

            // 4) 都没得干：等到最近一个分片可以重连的时刻，或最多 2 秒后重查
            var wakeAt = Date().addingTimeInterval(2)
            for at in retryAfter.values where at < wakeAt {
                wakeAt = at
            }
            condition.wait(until: max(wakeAt, Date().addingTimeInterval(0.05)))
            condition.unlock()
        }
    }

    /// 指数退避 + 抖动。
    /// 加抖动是因为所有分片通常在同一时刻被同一个事件打断，
    /// 不加扰动的话重连会挤在同一毫秒冲上去，容易再次被限流。
    private static func backoffDelay(attempt: Int) -> TimeInterval {
        let base = min(pow(1.9, Double(max(0, attempt - 2))), 30)
        return min(base + Double.random(in: 0...1.2), 32)
    }

    /// 轮转取下一个有数据的分片，避免低序号分片把高序号分片饿死
    private func firstIndexWithBufferedData() -> Int? {
        let count = segments.count
        guard count > 0 else { return nil }
        for step in 0..<count {
            let index = (cursor + step) % count
            if buffers[index]?.isEmpty == false {
                cursor = (index + 1) % count
                return index
            }
        }
        return nil
    }

    private func nextSegmentNeedingTask(now: Date) -> Int? {
        for index in segments.indices {
            if segmentDone.contains(index) { continue }
            if activeTasks[index] != nil { continue }
            if buffers[index]?.isEmpty == false { continue }
            // 还在退避窗口里的分片先跳过，让别的分片继续跑
            if let at = retryAfter[index], at > now { continue }
            return index
        }
        return nil
    }

    private func makeTask(for index: Int, from start: Int64) -> URLSessionDataTask {
        var request = URLRequest(url: spec.url)
        request.setValue(Prober.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in spec.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if spec.supportsRange && !isStreamMode {
            request.setValue("bytes=\(start)-\(segments[index].end)", forHTTPHeaderField: "Range")
        }
        return session.dataTask(with: request)
    }

    private func closeFileLocked() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: 收尾

    private func settle(with error: Error?) {
        condition.lock()
        if settled { condition.unlock(); return }
        settled = true
        condition.unlock()

        let callback = onCompletion
        onCompletion = nil
        guard let callback else { return }
        callbackQueue.async { callback(error) }
    }

    private func reportProgress() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard now - lastReport > 0.25 else { return }
        lastReport = now

        condition.lock()
        let received = segments.reduce(0) { $0 + $1.received }
        let total = spec.totalSize
        condition.unlock()

        let callback = onProgress
        callbackQueue.async { callback?(received, total) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        guard taskSegment[dataTask.taskIdentifier] != nil else {
            completionHandler(.cancel)
            return
        }

        if let http = response as? HTTPURLResponse {
            let start = taskStart[dataTask.taskIdentifier] ?? 0
            // 服务器无视 Range 直接回 200：此时返回的是整个文件，继续写会错位
            if start > 0 && http.statusCode == 200 {
                condition.lock()
                failure = NSError(domain: "YunX", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "服务器不支持断点续传（Range 请求被忽略），请删除任务后重新下载。"
                ])
                condition.broadcast()
                condition.unlock()
                completionHandler(.cancel)
                return
            }

            if http.statusCode >= 400 {
                // 5xx / 408 / 425 / 429 是临时性故障（服务器过载、限流、网关抖动），
                // 丢掉这次响应，交给写线程按退避策略重连；
                // 401 / 403 / 404 / 410 重试一万次也不会变好，直接整单失败。
                if Self.isTransientStatus(http.statusCode) {
                    condition.lock()
                    discardedTasks.insert(dataTask.taskIdentifier)
                    condition.broadcast()
                    condition.unlock()
                    completionHandler(.cancel)
                    return
                }

                condition.lock()
                failure = ProbeError.badStatus(http.statusCode)
                condition.broadcast()
                condition.unlock()
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    /// 这类状态码代表"现在不行"而不是"永远不行"
    private static func isTransientStatus(_ code: Int) -> Bool {
        if code == 408 || code == 425 || code == 429 { return true }
        return code >= 500
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = taskSegment[dataTask.taskIdentifier] else { return }

        condition.lock()
        // 被判定为临时故障的请求，body 是错误页，不能进缓冲
        if discardedTasks.contains(dataTask.taskIdentifier) {
            condition.unlock()
            return
        }
        lastDataAt = Date()
        // 这次连接确实下到了数据，说明链路是通的，只是被掐断了。
        // 把"连续失败"计数清零，下次重连就不用背长退避——
        // 否则各分片的重试次数只增不减，退避会一路涨到 30 秒，长尾特别难看。
        attempts[index] = 0
        buffers[index, default: []].append(data)
        bufferedBytes += data.count
        let overflow = bufferedBytes > highWater
        var toSuspend: [Int] = []
        if overflow {
            for (_, task) in activeTasks where !suspendedTasks.contains(task.taskIdentifier) {
                suspendedTasks.insert(task.taskIdentifier)
                toSuspend.append(task.taskIdentifier)
            }
        }
        condition.broadcast()
        condition.unlock()

        for id in toSuspend {
            activeTasks.values.first { $0.taskIdentifier == id }?.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = taskSegment[task.taskIdentifier] else { return }

        condition.lock()
        activeTasks.removeValue(forKey: index)
        taskSegment.removeValue(forKey: task.taskIdentifier)
        taskStart.removeValue(forKey: task.taskIdentifier)
        suspendedTasks.remove(task.taskIdentifier)
        discardedTasks.remove(task.taskIdentifier)

        if stopping || settled {
            condition.broadcast()
            condition.unlock()
            return
        }

        // 连接结束后先挂一个退避窗口。失败时避免立刻重连形成风暴；
        // 已经下满的分片不会再进入调度，这个时间戳对它们没有影响。
        retryAfter[index] = Date().addingTimeInterval(
            Self.backoffDelay(attempt: max(2, attempts[index] ?? 1))
        )

        let cancelled = (error as? URLError)?.code == .cancelled

        if isStreamMode {
            if let error, !cancelled {
                failure = error
            } else {
                // 长度未知：连接正常结束即视为该分片完成
                segments[index].end = max(segments[index].start - 1,
                                          segments[index].start + segments[index].received - 1)
                segmentDone.insert(index)
            }
        } else if let error, !cancelled {
            // 保留已下载部分，交给写线程按剩余区间重试
            _ = error
        }

        condition.broadcast()
        condition.unlock()
    }

    // MARK: 断点续传的分片规划

    /// 按并发数把总长度切成等长分片；过小的文件退化成单分片
    static func makeSegments(totalSize: Int64, connections: Int) -> [SegmentState] {
        guard totalSize > 0 else {
            return [SegmentState(start: 0, end: 0, received: 0)]
        }
        let minimumChunk: Int64 = 1024 * 512
        var count = max(1, connections)
        if totalSize < minimumChunk * Int64(count) {
            count = max(1, Int(totalSize / minimumChunk))
        }
        count = min(count, 64)

        let chunk = totalSize / Int64(count)
        var result: [SegmentState] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = (index == count - 1) ? totalSize - 1 : (start + chunk - 1)
            result.append(SegmentState(start: start, end: end, received: 0))
            start = end + 1
        }
        return result
    }
}
