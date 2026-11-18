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

    /// 本次连接实际收到的字节数，用来在连接结束时判断它是不是"空响应"
    private var taskBytes: [Int: Int64] = [:]
    /// 每个分片连续的空响应次数（收到数据即清零）
    private var emptyResponses: [Int: Int] = [:]
    /// 全局连续空响应次数，用来判断是不是整体被限流
    private var emptyStreak = 0
    /// 动态并发上限。
    ///
    /// 百度直链有个很麻烦的行为：请求太密时它不回 429，而是回一个
    /// `206 Partial Content` 但 body 长度为 0 —— 客户端看起来像"这段没数据"。
    /// 实测同一区间串行 8 次全空，静置 90 秒后单发 1.89 秒就能完整拿到。
    /// 所以一旦连续空响应，就要主动把并发压下来，否则越重连越被限得久。
    private var concurrencyCeiling: Int
    /// 每下满这么多字节，才允许把并发放宽一格。
    ///
    /// 这个值要平衡两件事：网盘普遍对单连接限速（百度免费账号约 100 KB/s），
    /// 所以要尽快把并发补回来；但补得太猛又会再撞限流。
    /// 4 MB 是个合适的台阶——按 100 KB/s 算约 40 秒才加一条，够稳也够快。
    private var bytesSinceRamp: Int64 = 0
    private let rampStep: Int64 = 4 * 1024 * 1024
    /// 新建连接的最小间隔。
    ///
    /// 开局 8 个分片会在同一毫秒一起发起请求，这一波本身就足够触发网盘限流。
    /// 把建连节奏摊开到每 0.4 秒一个，等于把瞬时请求数压到 2.5 个/秒以下，
    /// 代价只是开头多花两秒，却能从源头避免被拉黑。
    private var spawnGateAt = Date()
    private let spawnInterval: TimeInterval = 0.4

    private let highWater = 32 * 1024 * 1024
    private let lowWater = 8 * 1024 * 1024
    /// 单个分片允许的重连次数（只统计"真出错"的情况）。
    /// 一次网络抖动会同时打断所有分片，所以这个值要按最坏情况给足。
    private let maxAttempts = 30
    /// 空响应的容忍次数单独计。
    /// 被限流时给的时间要够长：退避能涨到 2 分钟，80 次足够跨过一小时以上的限流窗口，
    /// 期间只要有数据进来就清零。
    private let maxEmptyResponses = 80
    /// 连接活着但长时间一个字节都不来，就判定僵死并主动断开重连。
    /// 百度的 dlink 很常见这种"不报错也不吐数据"的挂死状态，60 秒足够判死。
    private let stallTimeout: TimeInterval = 60

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
        self.concurrencyCeiling = max(1, self.segments.count)
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
    func pause() -> [SegmentState] {        condition.lock()
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

            // 2) 该起新任务吗。并发受动态上限约束，被限流时会把上限压下来；
            //    建连节奏也做摊平，避免开局一波全打出去。
            let now = Date()
            if activeTasks.count < concurrencyCeiling,
               now >= spawnGateAt,
               let index = nextSegmentNeedingTask(now: now) {

                // 空响应和真错误分开计数：
                // 空响应是"现在被限流"，不该消耗掉那张有限的重连额度，
                // 否则一次几分钟的限流就能把额度耗光，任务直接判死。
                let emptyCount = emptyResponses[index] ?? 0
                if emptyCount > 0 {
                    if emptyCount > maxEmptyResponses {
                        failure = NSError(domain: "YunX", code: 2, userInfo: [
                            NSLocalizedDescriptionKey:
                                "服务器持续返回空响应 \(emptyCount) 次，已暂停。"
                                + "通常是网盘临时限流或直链失效，稍后点「继续」会从断点接着下。"
                        ])
                        condition.broadcast()
                        condition.unlock()
                        continue
                    }
                } else {
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
                }

                let start = writeOffset[index] ?? segments[index].start
                segments[index].received = start - segments[index].start
                let task = makeTask(for: index, from: start)
                activeTasks[index] = task
                taskSegment[task.taskIdentifier] = index
                taskStart[task.taskIdentifier] = start
                retryAfter.removeValue(forKey: index)
                spawnGateAt = Date().addingTimeInterval(spawnInterval)
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
            // 建连节流的等待时刻也要纳入唤醒时间，否则每建一个连接要多睡 2 秒
            if spawnGateAt > Date() && spawnGateAt < wakeAt {
                wakeAt = spawnGateAt
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

    /// 空响应（被限流）的退避比普通断线长得多。
    ///
    /// 这里是踩过坑的：一开始只给了 10 秒起步，结果每次都在限流窗口内重试，
    /// 重试又落空，N 轮下来全耗在等窗口上。实测百度的封锁窗口在以分钟计，
    /// 所以起步就得 30 秒，让第一次退避直接跨过整个窗口。
    private static func emptyBackoff(count: Int) -> TimeInterval {
        let base = min(30 * pow(1.5, Double(max(0, count - 1))), 180)
        return min(base + Double.random(in: 0...(base * 0.15 + 1)), 190)
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

    // MARK: 诊断

    func debugState() -> String {
        condition.lock(); defer { condition.unlock() }
        let pending = segments.indices.filter { !segmentDone.contains($0) }
        let detail = pending.map {
            "\($0):空\(emptyResponses[$0] ?? 0)/试\(attempts[$0] ?? 0)"
            + " 区间[\(segments[$0].start)-\(segments[$0].end)]"
            + " 已收\(segments[$0].received) 写位\(writeOffset[$0] ?? -1)"
        }.joined(separator: " | ")
        return "上限=\(concurrencyCeiling) 连空=\(emptyStreak) 在跑=\(activeTasks.count) 待办=\(pending.count) [\(detail)]"
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
        // 有数据进来就说明限流窗口过去了，空响应计数一并清零
        emptyResponses[index] = 0
        emptyStreak = 0
        taskBytes[dataTask.taskIdentifier, default: 0] += Int64(data.count)
        // 每下满 rampStep 才放宽一格并发，避免刚恢复就冲回满格再次被限
        bytesSinceRamp += Int64(data.count)
        if bytesSinceRamp >= rampStep {
            bytesSinceRamp = 0
            if concurrencyCeiling < segments.count { concurrencyCeiling += 1 }
        }
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
        // 本次连接到底收到了多少字节：0 字节是一个独立的信号，必须分辨出来
        let got = taskBytes.removeValue(forKey: task.taskIdentifier) ?? 0
        let wasDiscarded = discardedTasks.contains(task.taskIdentifier)

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

        if got == 0 && !wasDiscarded {
            // 一个字节都没给。绝大多数情况是网盘在限流：
            // 它回的是 206/200，状态码完全正常，只是 body 长度为 0，
            // 单看状态码会误以为"这段没数据"，实际是"你现在请求太多"。
            let count = (emptyResponses[index] ?? 0) + 1
            emptyResponses[index] = count
            emptyStreak += 1
            // 连续空响应说明问题不在某个分片，而在整体请求太密。
            // 直接压到串行：限流是按"单位时间请求数"算的，慢慢减半只是
            // 多触发几轮封锁，一次到底才停得下来。
            if emptyStreak >= 2 && concurrencyCeiling > 1 {
                concurrencyCeiling = 1
            }
            retryAfter[index] = Date().addingTimeInterval(Self.emptyBackoff(count: count))
        } else {
            // 有字节进来（或遇到真错误）。
            //
            // 只要这条连接真的下了数据，说明链路是通的，它只是被服务器按段结束了，
            // 短间隔后接着下一段即可，不该像真失败那样退避 1~2 秒。
            // 但也不能归零：完全没有节流地连续重连，会把请求速率顶上去，
            // 反而再次撞进限流（实测间隔 0.05 秒时，任务会被无限封锁在冷却期里）。
            let delay: TimeInterval = got > 0
                ? 0.25
                : Self.backoffDelay(attempt: max(2, attempts[index] ?? 1))
            retryAfter[index] = Date().addingTimeInterval(delay)
        }

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
