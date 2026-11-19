import Foundation
import SwiftUI
import AppKit
import Network

/// 列表里的一行任务：既有可持久化的 record，也有只存在内存里的实时速度。
@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    @Published var record: DownloadRecord
    @Published var speed: Double = 0
    @Published var isPreparing: Bool = false
    @Published var errorMessage: String?

    /// 下一次自动重试的时刻；非 nil 表示正在倒计时
    @Published var retryAt: Date?
    /// 这是第几次任务级重试，用来在界面上显示"第 N 次"
    @Published var retryAttempt: Int = 0
    /// 由 retryAt 换算出的剩余秒数，每 0.5 秒刷新一次
    @Published var retryCountdown: Int = 0

    nonisolated let id: UUID

    init(record: DownloadRecord) {
        self.id = record.id
        self.record = record
        self.retryAttempt = record.retryCount ?? 0
    }

    var received: Int64 { record.receivedBytes }
    var total: Int64 { record.totalSize }

    var progress: Double { record.progress }

    var status: JobStatus {
        get { record.status }
        set { record.status = newValue }
    }

    var etaSeconds: Double {
        guard speed > 1000, total > 0 else { return .infinity }
        let left = total - received
        guard left > 0 else { return 0 }
        return Double(left) / speed
    }
}

/// 任务池：负责探测、排队、并发控制、暂停恢复、持久化。
@MainActor
final class DownloadManager: ObservableObject {

    @Published private(set) var jobs: [DownloadJob] = []

    let settings: AppSettings

    private var downloaders: [UUID: SegmentedDownloader] = [:]
    private var pausing: Set<UUID> = []
    private var lastSample: [UUID: Int64] = [:]
    private var speedTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    /// 每个任务一个待触发的重试倒计时，暂停/删除任务时要能取消掉
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false
    private var wakeObserver: NSObjectProtocol?

    /// 任务级重试上限。中断属于可恢复故障，给一个很大的值等价于"一直重试直到成功"，
    /// 但保留上界，避免某个真·永久故障的任务在原地转上几天。
    private let maxJobRetries = 1000

    // MARK: 存储位置

    private static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("YunX-Mac-Desktop", isDirectory: true)
    }

    private static var storeURL: URL {
        supportDirectory.appendingPathComponent("tasks.json")
    }

    static var logDirectory: URL {
        supportDirectory
    }

    // MARK: 初始化

    init(settings: AppSettings) {
        self.settings = settings
        try? FileManager.default.createDirectory(at: Self.supportDirectory,
                                                 withIntermediateDirectories: true)
        load()
        startSpeedTimer()
        startNetworkMonitor()
        observeWake()
    }

    // MARK: 对外操作

    /// 新建任务：先探测响应头，再决定分片方案
    func enqueue(url: URL,
                 provider: Provider,
                 preferredName: String? = nil,
                 extraHeaders: [String: String] = [:],
                 knownSize: Int64 = -1,
                 relativePath: String? = nil) async {
        let resolved = resolveMirrorIfNeeded(url: url, provider: provider)
        // 多文件分享保持目录结构：相对路径的父目录落到下载目录下并提前建好
        let directory: String
        let name: String
        if let relativePath, !relativePath.isEmpty {
            let relative = (relativePath as NSString).standardizingPath
            let base = settings.downloadDirectory
            let parent = (relative as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                let full = URL(fileURLWithPath: base).appendingPathComponent(parent).path
                try? FileManager.default.createDirectory(atPath: full,
                                                         withIntermediateDirectories: true)
                directory = full
            } else {
                directory = base
            }
            name = (relative as NSString).lastPathComponent
        } else {
            directory = settings.downloadDirectory
            name = preferredName ?? "准备中…"
        }
        let record = DownloadRecord(
            sourceURL: url.absoluteString,
            finalURL: resolved.absoluteString,
            fileName: name,
            directoryPath: directory,
            provider: provider
        )
        var merged = extraHeaders
        if let existing = record.requestHeaders { merged.merge(existing) { new, _ in new } }

        let job = DownloadJob(record: record)
        job.record.requestHeaders = merged.isEmpty ? nil : merged
        job.isPreparing = true
        job.status = .queued
        jobs.insert(job, at: 0)

        do {
            let probe = try await Prober.probe(url: resolved, headers: merged)
            configure(job: job, probe: probe, preferredName: preferredName, knownSize: knownSize)
            job.isPreparing = false
            save()
            pump()
        } catch {
            job.isPreparing = false
            let reason = friendlyError(error)
            // 探测阶段断网 / 撞上 5xx 的，同样排进自动重试队列
            if settings.autoRetryEnabled, Self.isRetryable(error) {
                scheduleRetry(job, reason: reason)
            } else {
                job.status = .failed
                job.errorMessage = reason
                job.record.errorMessage = reason
                save()
            }
        }
    }

    /// 把探测结果写回任务记录。首次入队与"探测失败后重试"共用。
    private func configure(job: DownloadJob, probe: ProbeResult,
                           preferredName: String?, knownSize: Int64) {
        var updated = job.record
        let suggested = preferredName ?? probe.suggestedFileName
        // 重试探测时文件名已经定下来了，不能再改一次名，
        // 否则会绕开已经写了一半的 .yunxpart 断点文件
        if updated.fileName.isEmpty || updated.fileName == "准备中…" {
            updated.fileName = uniqueFileName(suggested,
                                              in: URL(fileURLWithPath: updated.directoryPath))
        }
        // 网盘接口通常已经给出准确大小，优先用它，避免探测结果偏差
        updated.totalSize = knownSize > 0 ? knownSize : probe.totalSize
        updated.supportsRange = probe.supportsRange
        if probe.supportsRange {
            updated.segments = SegmentedDownloader.makeSegments(
                totalSize: updated.totalSize,
                connections: settings.connectionsPerTask
            )
        } else {
            // 不支持 Range 的服务器只能单连接，续传视同重下
            updated.segments = [SegmentState(start: 0,
                                             end: max(0, updated.totalSize - 1),
                                             received: 0)]
        }
        updated.etag = probe.etag
        updated.lastModified = probe.lastModified
        updated.contentType = probe.contentType
        updated.finalURL = probe.finalURL.absoluteString
        job.record = updated
    }

    func start(_ job: DownloadJob) {
        guard job.status != .running, !job.isPreparing else { return }
        guard job.record.totalSize != 0 else { return }

        job.errorMessage = nil
        job.record.errorMessage = nil
        job.status = .running

        settings.ensureDirectoryExists()

        let sourceURL = URL(string: job.record.sourceURL)
        let target = sourceURL.map { resolveMirrorIfNeeded(url: $0, provider: job.record.provider) }
            ?? URL(string: job.record.finalURL ?? job.record.sourceURL)

        guard let target else {
            job.status = .failed
            job.errorMessage = "链接无效"
            save()
            return
        }

        var headers = defaultHeaders()
        if let extra = job.record.requestHeaders {
            // 网盘直链的 Referer / Cookie 必须盖过默认头，否则会 403
            headers.merge(extra) { _, new in new }
        }

        let spec = SegmentedDownloader.Spec(
            url: target,
            headers: headers,
            tempURL: job.record.temporaryURL,
            totalSize: job.record.totalSize,
            supportsRange: job.record.supportsRange,
            segments: job.record.segments.isEmpty
                ? SegmentedDownloader.makeSegments(totalSize: job.record.totalSize,
                                                   connections: settings.connectionsPerTask)
                : job.record.segments
        )

        let downloader = SegmentedDownloader(spec: spec)
        downloader.onProgress = { [weak job] received, total in
            guard let job else { return }
            Task { @MainActor in
                job.record.segments = Self.applyReceived(received: received,
                                                         total: total,
                                                         segments: job.record.segments)
            }
        }
        downloader.onCompletion = { [weak self, weak job] error in
            guard let job else { return }
            Task { @MainActor in
                self?.handleCompletion(job: job, error: error)
            }
        }

        downloaders[job.id] = downloader
        downloader.start()
        objectWillChange.send()
    }

    func pause(_ job: DownloadJob) {
        cancelRetry(job)
        guard let downloader = downloaders[job.id] else {
            job.status = .paused
            job.errorMessage = nil
            job.record.errorMessage = nil
            save()
            return
        }
        pausing.insert(job.id)
        job.speed = 0

        Task.detached(priority: .userInitiated) {
            let segments = downloader.pause()
            await MainActor.run {
                self.applyPaused(job: job, segments: segments)
            }
        }
    }

    func resume(_ job: DownloadJob) {
        cancelRetry(job)
        guard job.status == .paused || job.status == .failed else { return }
        // 手动继续视为重新开始计数，否则上一天的失败次数会一直累积
        job.record.retryCount = 0
        job.retryAttempt = 0
        job.status = .queued
        job.errorMessage = nil
        job.record.errorMessage = nil
        save()
        pump()
    }

    /// 删除任务，可选连带删除已下载的数据
    func remove(_ job: DownloadJob, deleteFiles: Bool) {
        cancelRetry(job)
        if job.status == .running || job.status == .queued {
            pausing.insert(job.id)
            downloaders[job.id]?.pause()
            downloaders.removeValue(forKey: job.id)
        }
        if deleteFiles {
            try? FileManager.default.removeItem(at: job.record.temporaryURL)
            try? FileManager.default.removeItem(at: job.record.destinationURL)
        }
        jobs.removeAll { $0.id == job.id }
        pausing.remove(job.id)
        save()
        objectWillChange.send()
        pump()
    }

    func reveal(_ job: DownloadJob) {
        let target: URL
        if job.status == .completed, FileManager.default.fileExists(atPath: job.record.destinationURL.path) {
            target = job.record.destinationURL
        } else {
            target = URL(fileURLWithPath: job.record.directoryPath)
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func open(_ job: DownloadJob) {
        guard job.status == .completed,
              FileManager.default.fileExists(atPath: job.record.destinationURL.path) else { return }
        NSWorkspace.shared.open(job.record.destinationURL)
    }

    /// 退出前把所有活动任务停到可恢复状态
    func shutdown() {
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        for (id, downloader) in downloaders {
            if let job = jobs.first(where: { $0.id == id }) {
                let segments = downloader.pause()
                job.record.segments = segments
                if job.status == .running { job.status = .paused }
            }
        }
        downloaders.removeAll()
        saveNow()
    }

    // MARK: 内部：完成/暂停

    private func handleCompletion(job: DownloadJob, error: Error?) {
        // pause() 也会回调 nil，这里要区分"真完成"和"我让你停"
        if pausing.contains(job.id) {
            return
        }
        // 先取快照再移除，保证失败时也能保住断点进度
        let snapshot = downloaders[job.id]?.snapshotSegments()
        downloaders.removeValue(forKey: job.id)

        if let error {
            if let snapshot, !snapshot.isEmpty {
                job.record.segments = snapshot
            }
            job.speed = 0
            let reason = friendlyError(error)

            // 断网、超时、连接重置、5xx、僵死连接这类属于可恢复故障：
            // 自动退避重试，不需要用户守在旁边点"继续"。
            // 403 / 404 / 链接过期 / 不支持 Range 这些重试也不会好，直接判失败。
            if settings.autoRetryEnabled, Self.isRetryable(error) {
                scheduleRetry(job, reason: reason)
                return
            }

            job.status = .failed
            job.errorMessage = reason
            job.record.errorMessage = reason
            if settings.notifyOnComplete {
                Notifier.failed(fileName: job.record.fileName, reason: reason)
            }
            save()
            pump()
            return
        }

        // 落盘：临时文件改名成最终文件
        let temp = job.record.temporaryURL
        var destination = job.record.destinationURL
        if FileManager.default.fileExists(atPath: destination.path) {
            let directory = URL(fileURLWithPath: job.record.directoryPath)
            job.record.fileName = uniqueFileName(job.record.fileName, in: directory)
            destination = job.record.destinationURL
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            job.record.segments = job.record.segments.map {
                SegmentState(start: $0.start, end: $0.end, received: $0.length)
            }
            job.record.completedAt = Date()
            job.status = .completed
            job.speed = 0
            // 下载成功才把连续失败计数清零，中途的几次重试不算数
            job.record.retryCount = 0
            job.retryAttempt = 0
            job.retryAt = nil
            job.retryCountdown = 0
            if settings.notifyOnComplete {
                Notifier.completed(fileName: job.record.fileName)
            }
        } catch {
            job.status = .failed
            job.errorMessage = "写入失败：\(error.localizedDescription)"
            job.record.errorMessage = job.errorMessage
        }

        save()
        pump()
    }

    private func applyPaused(job: DownloadJob, segments: [SegmentState]) {
        pausing.remove(job.id)
        downloaders.removeValue(forKey: job.id)
        job.record.segments = segments
        if job.status == .running || job.status == .queued {
            job.status = .paused
        }
        job.speed = 0
        save()
        pump()
    }

    // MARK: 内部：自动重试

    /// 安排一次任务级重试。
    /// 断点进度已经在 record.segments 里，重试走的是续传，不会从头再下一遍。
    private func scheduleRetry(_ job: DownloadJob, reason: String) {
        let attempt = (job.record.retryCount ?? 0) + 1
        guard attempt <= maxJobRetries else {
            job.status = .failed
            job.errorMessage = reason + "（已连续重试 \(maxJobRetries) 次）"
            job.record.errorMessage = job.errorMessage
            job.retryAt = nil
            job.retryCountdown = 0
            save()
            pump()
            return
        }

        job.record.retryCount = attempt
        job.retryAttempt = attempt
        job.status = .waitingRetry
        job.errorMessage = reason
        job.record.errorMessage = reason
        job.speed = 0

        let delay = Self.retryDelay(attempt: attempt)
        job.retryAt = Date().addingTimeInterval(delay)
        job.retryCountdown = Int(delay.rounded())
        scheduleRetryTimer(job: job, delay: delay)
        save()
        // 让出并发槽，其它排队的任务先跑
        pump()
    }

    private func scheduleRetryTimer(job: DownloadJob, delay: TimeInterval) {
        retryTasks[job.id]?.cancel()
        retryTasks[job.id] = Task { [weak self, weak job] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, let job else { return }
            await MainActor.run { self.fireRetry(job) }
        }
    }

    /// 立即执行一次重试：倒计时到点、网络恢复、系统唤醒、用户手动点，都走这里
    func fireRetry(_ job: DownloadJob) {
        retryTasks[job.id]?.cancel()
        retryTasks.removeValue(forKey: job.id)
        guard job.status == .waitingRetry else { return }

        job.retryAt = nil
        job.retryCountdown = 0
        job.errorMessage = nil
        job.record.errorMessage = nil

        // 一次都没探测成功过（比如刚建任务就断网），得先重新探测拿文件头
        if job.record.totalSize <= 0 || job.record.segments.isEmpty {
            job.status = .queued
            save()
            Task { await reprepare(job) }
            return
        }

        job.status = .queued
        save()
        pump()
    }

    /// 重新探测并配置任务，用于"探测阶段就失败、记录里还没有文件头信息"的情况
    private func reprepare(_ job: DownloadJob) async {
        guard let url = URL(string: job.record.sourceURL) else {
            job.status = .failed
            job.errorMessage = "链接无效"
            save()
            return
        }

        job.isPreparing = true
        let resolved = resolveMirrorIfNeeded(url: url, provider: job.record.provider)
        let headers = job.record.requestHeaders ?? [:]

        do {
            let probe = try await Prober.probe(url: resolved, headers: headers)
            configure(job: job, probe: probe,
                      preferredName: job.record.fileName, knownSize: -1)
            job.isPreparing = false
            job.status = .queued
            save()
            pump()
        } catch {
            job.isPreparing = false
            let reason = friendlyError(error)
            if settings.autoRetryEnabled, Self.isRetryable(error) {
                scheduleRetry(job, reason: reason)
            } else {
                job.status = .failed
                job.errorMessage = reason
                job.record.errorMessage = reason
                save()
            }
        }
    }

    private func cancelRetry(_ job: DownloadJob) {
        retryTasks[job.id]?.cancel()
        retryTasks.removeValue(forKey: job.id)
        job.retryAt = nil
        job.retryCountdown = 0
    }

    /// 退避：2 秒起指数增长，封顶 5 分钟。抖动是为了避免多个任务同一刻一起重连。
    private static func retryDelay(attempt: Int) -> TimeInterval {
        let base = min(pow(1.8, Double(max(0, attempt - 1))) * 2, 300)
        return base + Double.random(in: 0...3)
    }

    /// 判断一个错误是否值得重试。
    /// 原则：能自行恢复的（网络类、服务器临时故障）重试；
    /// 取决于资源本身状态的（404、403、链接过期、磁盘满）重试没用，直接判死。
    private static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError

        if ns.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: ns.code) {
            case .cancelled, .badURL, .unsupportedURL,
                 .userAuthenticationRequired, .fileDoesNotExist:
                return false
            default:
                // notConnectedToInternet / timedOut / networkConnectionLost /
                // cannotFindHost / dnsLookupFailed / cannotConnectToHost 等
                return true
            }
        }

        if let probe = error as? ProbeError {
            switch probe {
            case .badStatus(let code):
                return code >= 500 || code == 408 || code == 425 || code == 429
            case .notHTTP, .blocked:
                return false
            }
        }

        if ns.domain == "YunX" {
            switch ns.code {
            case 1: return false   // 建不了临时文件
            case 3: return false   // 服务器不支持 Range
            default: return true   // 2 = 分片重连次数耗尽，任务级再给一轮机会
            }
        }

        // 写盘失败（磁盘满、无权限）重试无意义
        if ns.domain == NSCocoaErrorDomain { return false }
        return true
    }

    /// 断网恢复后立刻重试，不用干等退避周期走完
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    guard self.wasOffline else { return }
                    self.wasOffline = false
                    for job in self.jobs where job.status == .waitingRetry {
                        self.fireRetry(job)
                    }
                } else {
                    self.wasOffline = true
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "yunx.network.monitor"))
    }

    /// 睡眠唤醒后，等待中的任务立刻重试：睡之前的连接基本都已经死了
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for job in self.jobs where job.status == .waitingRetry {
                    self.fireRetry(job)
                }
            }
        }
    }

    // MARK: 内部：排队

    private func pump() {
        let running = jobs.filter { $0.status == .running }.count
        var slots = max(1, settings.maxConcurrentTasks) - running
        guard slots > 0 else { return }

        for job in jobs where job.status == .queued && !job.isPreparing && job.record.totalSize != 0 {
            start(job)
            slots -= 1
            if slots <= 0 { break }
        }
    }

    // MARK: 内部：镜像

    private func resolveMirrorIfNeeded(url: URL, provider: Provider) -> URL {
        guard provider == .github, settings.mirrorEnabled else { return url }
        let prefix = settings.effectiveMirror
        guard !prefix.isEmpty else { return url }
        return MirrorTester.apply(prefix: prefix, to: url)
    }

    private func defaultHeaders() -> [String: String] {
        ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
    }

    // MARK: 内部：进度换算

    /// 引擎只报总进度，这里按比例摊回各分片，保证 UI 的百分比与列表一致
    private static func applyReceived(received: Int64, total: Int64,
                                      segments: [SegmentState]) -> [SegmentState] {
        guard total > 0, !segments.isEmpty else { return segments }
        var result = segments
        var remaining = received
        for index in result.indices {
            let take = min(result[index].length, remaining)
            result[index].received = max(result[index].received, take)
            remaining -= take
            if remaining <= 0 { break }
        }
        return result
    }

    private func startSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSpeed() }
        }
    }

    private func sampleSpeed() {
        for job in jobs {
            let current = job.received
            if job.status == .running {
                let previous = lastSample[job.id] ?? current
                let delta = max(0, current - previous)
                job.speed = Double(delta) / 0.5
            } else {
                job.speed = 0
            }
            lastSample[job.id] = current

            // 重试倒计时的秒数也跟着这个 0.5 秒的定时器走
            if let at = job.retryAt {
                let left = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
                if left != job.retryCountdown { job.retryCountdown = left }
            }
        }
    }

    // MARK: 内部：命名

    private func uniqueFileName(_ name: String, in directory: URL) -> String {
        let sanitized = Prober.sanitize(name)
        let candidate = directory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return sanitized }

        let ext = (sanitized as NSString).pathExtension
        let base = (sanitized as NSString).deletingPathExtension
        var index = 1
        while index < 1000 {
            let next = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(next).path) {
                return next
            }
            index += 1
        }
        return "\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)"
    }

    private func friendlyError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "网络未连接"
            case NSURLErrorTimedOut: return "连接超时，请检查网络或代理设置"
            case NSURLErrorCannotFindHost: return "域名解析失败"
            case NSURLErrorSecureConnectionFailed: return "TLS 握手失败，该站点证书不被信任"
            case NSURLErrorCancelled: return "已取消"
            default: return ns.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
            return
        }
        jobs = records.map { record in
            var fixed = record
            // 上次退出时还在跑、或正在等待重试的，重启后一律视为已暂停
            // （重试定时器已经不在了，得让用户点一下继续）
            if fixed.status == .running || fixed.status == .queued || fixed.status == .waitingRetry {
                fixed.status = .paused
            }
            return DownloadJob(record: fixed)
        }
    }

    /// 合并短时间内的多次保存，避免下载时疯狂写盘
    private func save() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveNow() {
        var snapshot: [DownloadRecord] = []
        for job in jobs {
            var record = job.record
            if record.status == .running {
                record.segments = downloaders[job.id]?.snapshotSegments() ?? record.segments
            }
            snapshot.append(record)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
