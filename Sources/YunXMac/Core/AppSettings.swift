import Foundation

/// 应用设置。落地到 UserDefaults，键值用 Codable 整体序列化，避免十几个散落键。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private static let storageKey = "cn.yunxmac.settings.v1"

    @Published var downloadDirectory: String {
        didSet { persist() }
    }
    /// 同时进行的任务数
    @Published var maxConcurrentTasks: Int {
        didSet { persist() }
    }
    /// 单任务分片并发数
    @Published var connectionsPerTask: Int {
        didSet { persist() }
    }
    /// 全局限速，单位 KB/s，0 表示不限速
    @Published var speedLimitKBps: Int {
        didSet {
            persist()
            Throttle.shared.setLimit(bytesPerSecond: Int64(speedLimitKBps) * 1024)
        }
    }
    @Published var watchClipboard: Bool {
        didSet { persist() }
    }
    @Published var notifyOnComplete: Bool {
        didSet { persist() }
    }
    @Published var mirrorEnabled: Bool {
        didSet { persist() }
    }
    /// 为空表示"自动选择最快镜像"
    @Published var mirrorPrefix: String {
        didSet { persist() }
    }
    @Published var mirrorCandidates: [String] {
        didSet { persist() }
    }

    /// 最近一次自动测速的赢家
    @Published var lastMirrorWinner: String = "" {
        didSet { persist() }
    }

    // MARK: 初始化

    init() {
        let snapshot = Self.load()
        let defaultDirectory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunX").path
            ?? NSHomeDirectory() + "/Downloads/YunX"

        downloadDirectory = snapshot?.downloadDirectory ?? defaultDirectory
        maxConcurrentTasks = snapshot?.maxConcurrentTasks ?? 2
        connectionsPerTask = snapshot?.connectionsPerTask ?? 8
        speedLimitKBps = snapshot?.speedLimitKBps ?? 0
        watchClipboard = snapshot?.watchClipboard ?? false
        notifyOnComplete = snapshot?.notifyOnComplete ?? true
        mirrorEnabled = snapshot?.mirrorEnabled ?? true
        mirrorPrefix = snapshot?.mirrorPrefix ?? ""
        mirrorCandidates = snapshot?.mirrorCandidates ?? Self.defaultMirrors
        lastMirrorWinner = snapshot?.lastMirrorWinner ?? ""

        Throttle.shared.setLimit(bytesPerSecond: Int64(speedLimitKBps) * 1024)
        ensureDirectoryExists()
    }

    static let defaultMirrors = [
        "https://ghfast.top",
        "https://gh-proxy.com",
        "https://ghproxy.net",
        "https://gh-proxy.net",
        "https://gh.llkk.cc"
    ]

    // MARK: 便捷属性

    var effectiveMirror: String {
        if !mirrorPrefix.isEmpty { return MirrorTester.normalize(mirrorPrefix) }
        return MirrorTester.normalize(lastMirrorWinner)
    }

    func ensureDirectoryExists() {
        let url = URL(fileURLWithPath: downloadDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: 持久化

    private struct Snapshot: Codable {
        var downloadDirectory: String
        var maxConcurrentTasks: Int
        var connectionsPerTask: Int
        var speedLimitKBps: Int
        var watchClipboard: Bool
        var notifyOnComplete: Bool
        var mirrorEnabled: Bool
        var mirrorPrefix: String
        var mirrorCandidates: [String]
        var lastMirrorWinner: String
    }

    private static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func persist() {
        let snapshot = Snapshot(
            downloadDirectory: downloadDirectory,
            maxConcurrentTasks: maxConcurrentTasks,
            connectionsPerTask: connectionsPerTask,
            speedLimitKBps: speedLimitKBps,
            watchClipboard: watchClipboard,
            notifyOnComplete: notifyOnComplete,
            mirrorEnabled: mirrorEnabled,
            mirrorPrefix: mirrorPrefix,
            mirrorCandidates: mirrorCandidates,
            lastMirrorWinner: lastMirrorWinner
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
