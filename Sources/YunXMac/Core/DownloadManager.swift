import Foundation
import SwiftUI

/// 列表里的一行任务：既有可持久化的 record，也有只存在内存里的实时速度。
@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    @Published var record: DownloadRecord
    @Published var speed: Double = 0
    @Published var isPreparing: Bool = false
    @Published var errorMessage: String?

    nonisolated let id: UUID

    init(record: DownloadRecord) {
        self.id = record.id
        self.record = record
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
    }

    // MARK: 对外操作

    /// 新建任务：先探测响应头，再决定分片方案
    func enqueue(url: URL,
                 provider: Provider,
                 preferredName: String? = nil,
                 extraHeaders: [String: String] = [:],
                 knownSize: Int64 = -1) async {
        let resolved = resolveMirrorIfNeeded(url: url, provider: provider)
        let record = DownloadRecord(
            sourceURL: url.absoluteString,
            finalURL: resolved.absoluteString,
            fileName: preferredName ?? "准备中…",
            directoryPath: settings.downloadDirectory,
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
            var updated = job.record
            let suggested = preferredName ?? probe.suggestedFileName
            updated.fileName = uniqueFileName(suggested,
                                              in: URL(fileURLWithPath: updated.directoryPath))
            // 网盘接口通常已经给出准确大小，优先用它，避免探测结果偏差
            updated.totalSize = knownSize > 0 ? knownSize : probe.totalSize
            updated.supportsRange = probe.supportsRange
            if probe.supportsRange {
                updated.segments = SegmentedDownloader.makeSegments(
                    totalSize: probe.totalSize,
                    connections: settings.connectionsPerTask
                )
            } else {
                // 不支持 Range 的服务器只能单连接，续传视同重下
                updated.segments = [SegmentState(start: 0,
                                                end: max(0, probe.totalSize - 1),
                                                received: 0)]
            }
            updated.etag = probe.etag
            updated.lastModified = probe.lastModified
            updated.contentType = probe.contentType
            updated.finalURL = probe.finalURL.absoluteString
            job.record = updated
            job.isPreparing = false
            save()
            pump()
        } catch {
            job.isPreparing = false
            job.status = .failed
            job.errorMessage = friendlyError(error)
            job.record.errorMessage = job.errorMessage
            save()
        }
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
        guard let downloader = downloaders[job.id] else {
            job.status = .paused
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
        guard job.status == .paused || job.status == .failed else { return }
        job.status = .queued
        job.errorMessage = nil
        save()
        pump()
    }

    /// 删除任务，可选连带删除已下载的数据
    func remove(_ job: DownloadJob, deleteFiles: Bool) {
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
            job.status = .failed
            job.errorMessage = friendlyError(error)
            job.record.errorMessage = job.errorMessage
            job.speed = 0
            if settings.notifyOnComplete {
                Notifier.failed(fileName: job.record.fileName, reason: job.errorMessage ?? "")
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
            // 上次退出时还在跑的，重启后一律视为已暂停
            if fixed.status == .running || fixed.status == .queued {
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
