import Foundation

/// 从任意文本里抽出链接、判断来源、顺便把提取码带上。
/// 纯本地规则，不发任何网络请求。
enum LinkParser {

    // MARK: 正则

    /// 普通 http(s) 链接；遇到中英文标点、空白、引号、括号即截断
    private static let httpPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s"'<>\u3000，。、；;）)】\]】”’]+"#,
        options: [.caseInsensitive]
    )

    private static let magnetPattern = try! NSRegularExpression(
        pattern: #"magnet:\?[^\s"'<>）)】]+"#,
        options: [.caseInsensitive]
    )

    private static let ed2kPattern = try! NSRegularExpression(
        pattern: #"ed2k://[^\s"'<>）)】]+"#,
        options: [.caseInsensitive]
    )

    /// 提取码 / 密码 / pwd：支持 "提取码：abcd"、"密码 abcd"、"pwd=abcd"、"?pwd=abcd"
    private static let codePattern = try! NSRegularExpression(
        pattern: #"(?:提取码|访问码|密码|口令|pwd|code)\s*[:：=]?\s*([A-Za-z0-9]{4,8})"#,
        options: [.caseInsensitive]
    )

    // MARK: 主入口

    /// 解析一段文本，返回其中所有可识别链接（去重、保持出现顺序）
    static func parse(text: String) -> [ParsedLink] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [ParsedLink] = []
        var seen = Set<String>()

        for raw in extractRawLinks(from: trimmed) {
            let key = raw.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)

            let provider = detectProvider(raw: raw)
            let code = provider.kind == .share ? extractShareCode(from: trimmed, near: raw) : nil
            results.append(
                ParsedLink(raw: raw, url: URL(string: raw), provider: provider, shareCode: code)
            )
        }
        return results
    }

    /// 单个链接快速解析（用于剪贴板监听）
    static func parseFirst(text: String) -> ParsedLink? {
        parse(text: text).first
    }

    // MARK: 抽取

    private static func extractRawLinks(from text: String) -> [String] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(Int, String)] = []

        for regex in [httpPattern, magnetPattern, ed2kPattern] {
            regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                found.append((match.range.location, String(text[range])))
            }
        }
        return found.sorted { $0.0 < $1.0 }.map { trimTrailingPunctuation($0.1) }
    }

    /// 去掉链接尾部被中文文案粘上的标点
    private static func trimTrailingPunctuation(_ raw: String) -> String {
        var value = raw
        let trailing = CharacterSet(charactersIn: ".,;:!?，。、；：！？)）】]》”’\"'")
        while let last = value.unicodeScalars.last, trailing.contains(last) {
            value.removeLast()
        }
        return value
    }

    // MARK: 来源识别

    static func detectProvider(raw: String) -> Provider {
        let lower = raw.lowercased()

        if lower.hasPrefix("magnet:?") { return .magnet }
        if lower.hasPrefix("ed2k://") { return .ed2k }
        if lower.hasSuffix(".torrent") { return .torrent }

        guard let url = URL(string: raw), let host = url.host?.lowercased() else {
            return .unknown
        }

        func hostMatch(_ needles: [String]) -> Bool {
            needles.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        if hostMatch(["pan.quark.cn", "quark.cn"]) { return .quark }
        if hostMatch(["drive.uc.cn", "fast.uc.cn", "uc.cn"]) { return .uc }
        if hostMatch(["pan.baidu.com", "yun.baidu.com", "eyun.baidu.com"]) { return .baidu }
        if host.contains("lanzou") || host.contains("lanzt") || host.contains("ilanzou") { return .lanzou }
        if hostMatch(["123pan.cn", "123684.com", "123865.com", "123912.com", "123pan.com", "pan.123684.com"]) { return .pan123 }
        if hostMatch(["115.com", "anxia.com", "115cdn.com"]) { return .pan115 }
        if hostMatch(["pan.xunlei.com", "xunlei.com"]) { return .xunlei }
        if hostMatch(["cloud.139.com", "caiyun.139.com"]) { return .cloud139 }
        if hostMatch(["aliyundrive.com", "alipan.com"]) { return .aliyun }
        if hostMatch(["github.com", "raw.githubusercontent.com", "gist.github.com", "objects.githubusercontent.com"]) { return .github }
        if hostMatch(["bilibili.com", "b23.tv"]) { return .bilibili }
        if hostMatch(["douyin.com", "iesdouyin.com"]) { return .douyin }
        if hostMatch(["xiaohongshu.com", "xhslink.com"]) { return .xiaohongshu }
        if hostMatch(["weibo.com", "weibo.cn"]) { return .weibo }
        if hostMatch(["kuaishou.com", "gifshow.com"]) { return .kuaishou }
        if hostMatch(["acfun.cn"]) { return .acfun }
        if hostMatch(["pixiv.net"]) { return .pixiv }

        // 分享页里常见的一级域名判断完还没命中，就看路径是不是个文件名
        if looksLikeDirectFile(url) { return .direct }
        return .unknown
    }

    /// 路径末段带扩展名，才认为是可直链下载的文件
    private static func looksLikeDirectFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return false }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard ext.count >= 1, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return false
        }
        return true
    }

    // MARK: 提取码

    /// 优先在链接附近找，其次全局找；分享链接自带的 ?pwd= 也认
    static func extractShareCode(from text: String, near raw: String) -> String? {
        if let url = URL(string: raw),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let pwd = components.queryItems?.first(where: {
               ["pwd", "passcode", "password", "code"].contains($0.name.lowercased())
           })?.value,
           !pwd.isEmpty {
            return pwd
        }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 先找链接之后 120 字符内的
        if let linkRange = text.range(of: raw) {
            let start = text.utf16.distance(from: text.startIndex, to: linkRange.lowerBound)
            let searchStart = min(start + raw.utf16.count, ns.length)
            let length = min(120, ns.length - searchStart)
            if length > 0,
               let match = codePattern.firstMatch(in: text, options: [],
                                                  range: NSRange(location: searchStart, length: length)),
               let captured = Range(match.range(at: 1), in: text) {
                return String(text[captured])
            }
        }

        if let match = codePattern.firstMatch(in: text, options: [], range: full),
           let captured = Range(match.range(at: 1), in: text) {
            return String(text[captured])
        }
        return nil
    }
}
