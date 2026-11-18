import Foundation

/// 分享页解析出的可下载目标
struct ResolvedFile {
    /// 直链（或需要跟着 302 才能到真实文件的地址）
    var url: URL
    var fileName: String
    var size: Int64
    /// 下载该直链必须带的请求头（Referer / UA / Cookie 各家不同）
    var headers: [String: String]
    var provider: Provider
    /// 结果里的补充说明，比如"共 3 个文件，本次下载第 1 个"
    var note: String?
}

enum PanResolveError: LocalizedError {
    case notSignedIn(Provider)
    case needPasscode(Provider)
    case wrongPasscode
    case linkInvalid(String)
    case emptyShare
    case credentialExpired(Provider)
    case platform(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let provider):
            return "\(provider.displayName)需要先登录账号"
        case .needPasscode(let provider):
            return "这条\(provider.displayName)分享需要提取码，请在链接后补上提取码再试"
        case .wrongPasscode:
            return "提取码不正确"
        case .linkInvalid(let detail):
            return detail
        case .emptyShare:
            return "分享里没有可下载的文件"
        case .credentialExpired(let provider):
            return "\(provider.displayName)登录已失效，请重新登录"
        case .platform(let message):
            return message
        }
    }
}

protocol PanResolver {
    var provider: Provider { get }
    /// 未登录也能拿到文件名/大小，用来在列表里先显示，避免用户点下载才发现没登录
    func preview(link: ParsedLink) async throws -> [PanShareEntry]
    func resolve(link: ParsedLink, credential: PanCredential) async throws -> ResolvedFile
}

/// 分享里的一个条目
struct PanShareEntry {
    var name: String
    var size: Int64
    var isDirectory: Bool
    var id: String
    /// 夸克/UC 需要每组文件的 token
    var extraToken: String?
}

// MARK: - 网络小工具

/// 分享解析用的轻量 HTTP 客户端：自己管 cookie，不污染全局 URLSession
final class PanHTTP {

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let session: URLSession
    private let lock = NSLock()
    private var cookies: [String: String] = [:]

    init(seed: [String: String] = [:]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 百度 dlink 会 302 到 d.pcs.baidu.com，必须跟到底
        session = URLSession(configuration: configuration)
        setCookies(seed)
    }

    func setCookies(_ values: [String: String]) {
        lock.lock()
        for (name, value) in values where !name.isEmpty && name != "undefined" {
            cookies[name] = value
        }
        lock.unlock()
    }

    func allCookies() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return cookies
    }

    private var cookieHeader: String {
        allCookies().sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 一个 header 里可能压了多条 cookie（形如 "a=1; Path=/, b=2; Path=/"），
    /// 只在「逗号 + 紧跟 name=」处切开，避免把 Expires=Wed, 21 Oct 里的逗号当分隔符
    private static let cookieSeparator = try! NSRegularExpression(
        pattern: ",\\s*(?=[A-Za-z0-9_\\-]+=)"
    )

    private static func splitCookieHeader(_ raw: String) -> [String] {
        let ns = raw as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = cookieSeparator.matches(in: raw, options: [], range: range)
        guard !matches.isEmpty else { return [raw] }

        var pieces: [String] = []
        var cursor = 0
        for match in matches {
            pieces.append(ns.substring(with: NSRange(location: cursor,
                                                     length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 从 Set-Cookie 里吸收新 cookie
    private func absorb(_ response: HTTPURLResponse?) {
        guard let response else { return }
        var fresh: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String,
                  name.lowercased() == "set-cookie",
                  let raw = value as? String else { continue }

            for piece in Self.splitCookieHeader(raw) {
                let first = piece.components(separatedBy: ";").first ?? piece
                guard let equalIndex = first.firstIndex(of: "=") else { continue }
                let cookieName = first[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let cookieValue = first[first.index(after: equalIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !cookieName.isEmpty else { continue }
                fresh[cookieName] = cookieValue
            }
        }
        if !fresh.isEmpty { setCookies(fresh) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mutable = request
        if mutable.value(forHTTPHeaderField: "User-Agent") == nil {
            mutable.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let cookieValue = cookieHeader
        if !cookieValue.isEmpty {
            mutable.setValue(cookieValue, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: mutable)
        let http = response as? HTTPURLResponse
        absorb(http)
        guard let http else {
            throw PanResolveError.platform("服务器没有返回有效响应")
        }
        return (data, http)
    }

    func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw PanResolveError.platform("返回的不是 JSON：\(preview)")
        }
        return object
    }
}

// MARK: - 链接工具

enum PanLink {

    /// 百度：https://pan.baidu.com/s/1AbCdEf -> 真实 surl 是去掉首字符 1
    /// 也支持 /share/init?surl=AbCdEf 与带 ?pwd= 的形式
    ///
    /// 注意百度有两套写法且不能混用：
    /// - `share/list` 要**去掉开头 1** 的短 ID
    /// - `share/tplconfig` 要**保留开头 1** 的原始 URL 段
    static func baiduSurl(from url: URL) -> String? {
        guard let raw = baiduRawToken(from: url) else { return nil }
        var token = raw
        if token.count > 1, token.hasPrefix("1") { token.removeFirst() }
        return token
    }

    /// 保留开头 1 的原始形式，tplconfig 等接口需要
    static func baiduRawToken(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let surl = components?.queryItems?.first(where: { $0.name == "surl" })?.value,
           !surl.isEmpty {
            return surl
        }
        let path = url.path
        guard let range = path.range(of: "/s/") else { return nil }
        let token = String(path[range.upperBound...]).components(separatedBy: "/").first ?? ""
        return token.isEmpty ? nil : token
    }

    /// 夸克 / UC：https://pan.quark.cn/s/abcdef -> abcdef
    static func quarkPwdID(from url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: "/s/") else { return nil }
        let token = String(path[range.upperBound...]).components(separatedBy: "/").first ?? ""
        return token.isEmpty ? nil : token
    }
}
