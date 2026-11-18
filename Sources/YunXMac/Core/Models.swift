import Foundation

// MARK: - 网盘 / 平台标识

/// 链接来源分类，决定后续走"直链下载"还是"分享页解析"。
enum ProviderKind {
    /// 可以直接拿到 HTTP 直链，走多线程分片下载
    case direct
    /// 需要账号授权的分享页（网盘）
    case share
    /// 视频平台作品页
    case media
    /// P2P（磁力 / BT / ed2k），本版本只做识别与转交
    case p2p
    case unknown
}

enum Provider: String, Codable, CaseIterable, Identifiable {
    case direct
    case github
    case quark
    case uc
    case baidu
    case lanzou
    case pan123
    case pan115
    case xunlei
    case cloud139
    case aliyun
    case bilibili
    case douyin
    case xiaohongshu
    case weibo
    case kuaishou
    case acfun
    case pixiv
    case magnet
    case ed2k
    case torrent
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "HTTP 直链"
        case .github: return "GitHub"
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .baidu: return "百度网盘"
        case .lanzou: return "蓝奏云"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .xunlei: return "迅雷网盘"
        case .cloud139: return "139 云盘"
        case .aliyun: return "阿里云盘"
        case .bilibili: return "哔哩哔哩"
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .weibo: return "微博"
        case .kuaishou: return "快手"
        case .acfun: return "AcFun"
        case .pixiv: return "Pixiv"
        case .magnet: return "磁力链接"
        case .ed2k: return "eD2k"
        case .torrent: return "BT 种子"
        case .unknown: return "未知来源"
        }
    }

    var kind: ProviderKind {
        switch self {
        case .direct, .github: return .direct
        case .quark, .uc, .baidu, .lanzou, .pan123, .pan115, .xunlei, .cloud139, .aliyun: return .share
        case .bilibili, .douyin, .xiaohongshu, .weibo, .kuaishou, .acfun, .pixiv: return .media
        case .magnet, .ed2k, .torrent: return .p2p
        case .unknown: return .unknown
        }
    }

    /// SF Symbols 名称，用于列表与解析结果卡片
    var symbolName: String {
        switch self {
        case .direct: return "link"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .quark: return "q.circle"
        case .uc: return "u.circle"
        case .baidu: return "b.circle"
        case .lanzou: return "l.circle"
        case .pan123: return "1.circle"
        case .pan115: return "5.circle"
        case .xunlei: return "bolt.horizontal.circle"
        case .cloud139: return "c.circle"
        case .aliyun: return "cloud.circle"
        case .bilibili: return "play.rectangle"
        case .douyin: return "music.note"
        case .xiaohongshu: return "book.circle"
        case .weibo: return "w.circle"
        case .kuaishou: return "k.circle"
        case .acfun: return "a.circle"
        case .pixiv: return "p.circle"
        case .magnet: return "magnifyingglass.circle"
        case .ed2k: return "e.circle"
        case .torrent: return "doc.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// 该来源是否能在本版本里真正下载
    var isDownloadableInThisVersion: Bool {
        switch kind {
        case .direct: return true
        default: return false
        }
    }
}

// MARK: - 解析结果

struct ParsedLink: Identifiable, Hashable {
    let id = UUID()
    var raw: String
    var url: URL?
    var provider: Provider
    var shareCode: String?

    var host: String { url?.host ?? "" }
}

// MARK: - 任务状态

enum JobStatus: String, Codable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var isFinished: Bool {
        self == .completed || self == .cancelled
    }

    var isActive: Bool {
        self == .running || self == .queued
    }
}

// MARK: - 分片状态

struct SegmentState: Codable, Hashable {
    var start: Int64
    /// 闭区间末字节
    var end: Int64
    var received: Int64

    var length: Int64 { max(0, end - start + 1) }
    var remaining: Int64 { max(0, length - received) }
    var isDone: Bool { remaining == 0 }
    var nextOffset: Int64 { start + received }
}

// MARK: - 可持久化任务记录

struct DownloadRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var sourceURL: String
    var finalURL: String?
    var fileName: String
    var directoryPath: String
    var totalSize: Int64 = -1
    var segments: [SegmentState] = []
    var supportsRange: Bool = true
    var etag: String?
    var lastModified: String?
    var contentType: String?
    var createdAt: Date = Date()
    var completedAt: Date?
    var status: JobStatus = .queued
    var provider: Provider = .direct
    var mirrorPrefix: String?
    var errorMessage: String?

    var destinationURL: URL {
        URL(fileURLWithPath: directoryPath).appendingPathComponent(fileName)
    }

    /// 下载中的临时文件（与最终文件同目录，保证同一卷，rename 是原子的）
    var temporaryURL: URL {
        URL(fileURLWithPath: directoryPath).appendingPathComponent(".\(fileName).yunxpart")
    }

    var receivedBytes: Int64 {
        segments.reduce(0) { $0 + $1.received }
    }

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalSize))
    }
}

// MARK: - 格式化工具

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "--" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 86_400 * 7 else { return "--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
