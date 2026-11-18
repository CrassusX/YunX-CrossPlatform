import Foundation

/// 百度网盘分享解析。
///
/// 完整链路：首页拿 BAIDUID → 提取码 verify 换 BDCLND → 列目录 → 转存到自己网盘 → 取直链。
///
/// 为什么必须转存：百度从 2020 年后收掉了「分享未转存文件直接给直链」的能力。
/// 实测 `/api/sharedownload` 对着分享 fs_id 一律回 `errno 2`，
/// 只有对**自己网盘里**的文件 `/api/filemetas?dlink=1` 才给可用地址。
/// 所以这里走的是「转存 → 取自己文件的 dlink」，转存目标放在固定目录下，方便事后清理。
struct BaiduPanResolver: PanResolver {

    let provider: Provider = .baidu

    private static let appID = "250528"
    /// 转存落地目录，集中放便于一键清理
    static let transferRoot = "/来自分享"

    private func baseQuery() -> String {
        "channel=chunlei&web=1&app_id=\(Self.appID)&clienttype=0"
    }

    // MARK: 预览（未登录也能拿到文件列表）

    func preview(link: ParsedLink) async throws -> [PanShareEntry] {
        let http = PanHTTP()
        try await bootstrap(http)
        return try await listFiles(http: http, link: link).entries
    }

    // MARK: 解析出直链

    func resolve(link: ParsedLink, credential: PanCredential) async throws -> ResolvedFile {
        let http = PanHTTP(seed: credential.cookies)
        try await bootstrap(http)

        let listed = try await listFiles(http: http, link: link)
        let downloadable = listed.entries.filter { !$0.isDirectory }
        guard let first = downloadable.first else {
            throw PanResolveError.emptyShare
        }

        let token = try await fetchBdToken(http: http)
        let saved = try await transfer(http: http,
                                       link: link,
                                       entry: first,
                                       shareID: listed.shareID,
                                       uk: listed.uk,
                                       bdstoken: token)
        let dlink = try await fetchDLink(http: http, fsID: saved.fsID, bdstoken: token)

        var headers = [
            "Referer": "https://pan.baidu.com/disk/home",
            // 百度 pcs 下载对 UA 敏感，用网盘自己的
            "User-Agent": "pan.baidu.com",
            "Cookie": http.allCookies()
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
        ]
        if headers["Cookie"]?.isEmpty ?? true { headers.removeValue(forKey: "Cookie") }

        var note = saved.reused
            ? "该文件已在你网盘中：\(saved.path)"
            : "已转存到你网盘的 \(saved.path)，可稍后自行清理"
        if downloadable.count > 1 {
            note = "分享共 \(downloadable.count) 个文件，本次下载第 1 个；" + note
        }

        return ResolvedFile(
            url: dlink,
            fileName: first.name,
            size: first.size,
            headers: headers,
            provider: .baidu,
            note: note
        )
    }

    // MARK: 各步骤

    /// 首页是为了拿到 BAIDUID，后续 verify 与 list 都依赖它
    private func bootstrap(_ http: PanHTTP) async throws {
        var request = URLRequest(url: URL(string: "https://pan.baidu.com/")!)
        request.setValue(PanHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await http.send(request)
    }

    private struct Listed {
        var entries: [PanShareEntry]
        /// 转存接口需要的分享 ID
        var shareID: String
        /// 分享者的 uk
        var uk: String
    }

    private func listFiles(http: PanHTTP, link: ParsedLink) async throws -> Listed {
        guard let url = link.url, let surl = PanLink.baiduSurl(from: url) else {
            throw PanResolveError.linkInvalid("无法从链接里识别出百度网盘分享 ID")
        }

        // 有提取码就先换 BDCLND，无码分享直接列目录
        if let code = link.shareCode, !code.isEmpty {
            let verified = try await verifyPasscode(http: http, surl: surl, code: code)
            if !verified { throw PanResolveError.wrongPasscode }
        }

        var components = URLComponents(string: "https://pan.baidu.com/share/list")!
        components.percentEncodedQuery = "shorturl=\(surl)&dir=%2F&root=1&page=1&num=100"
            + "&order=time&desc=1&" + baseQuery()

        var request = URLRequest(url: components.url!)
        request.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let payload = try await http.json(request)
        let errno = payload["errno"] as? Int ?? -1

        switch errno {
        case 0:
            break
        case -9:
            throw PanResolveError.wrongPasscode
        case 105, 140:
            throw PanResolveError.linkInvalid("分享已失效或被取消")
        case -6:
            throw PanResolveError.credentialExpired(.baidu)
        default:
            let message = payload["show_msg"] as? String ?? "errno \(errno)"
            throw PanResolveError.platform("百度网盘返回错误：\(message)")
        }

        let shareID = (payload["share_id"] as? NSNumber)?.stringValue
            ?? (payload["share_id"] as? String) ?? ""
        let uk = (payload["uk"] as? NSNumber)?.stringValue
            ?? (payload["uk"] as? String) ?? ""

        let list = payload["list"] as? [[String: Any]] ?? []
        if list.isEmpty, let name = shareTitleFileName(payload) {
            // 单文件分享时信息在外层
            return Listed(
                entries: [PanShareEntry(name: name, size: 0, isDirectory: false, id: "")],
                shareID: shareID, uk: uk
            )
        }

        let entries: [PanShareEntry] = list.compactMap { item in
            guard let name = item["server_filename"] as? String else { return nil }
            let isDir = (item["isdir"] as? Int ?? 0) == 1
            let size = (item["size"] as? NSNumber)?.int64Value
                ?? Int64(item["size"] as? String ?? "0") ?? 0
            let fsID = (item["fs_id"] as? NSNumber)?.stringValue
                ?? String(describing: item["fs_id"] ?? "")
            return PanShareEntry(name: name, size: size, isDirectory: isDir, id: fsID)
        }

        if entries.isEmpty { throw PanResolveError.emptyShare }
        return Listed(entries: entries, shareID: shareID, uk: uk)
    }

    /// 单文件分享时 title 形如 "/路径/文件名.mp4"，取最后一段
    private func shareTitleFileName(_ payload: [String: Any]) -> String? {
        guard let title = payload["title"] as? String, !title.isEmpty else { return nil }
        let name = (title as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func verifyPasscode(http: PanHTTP, surl: String, code: String) async throws -> Bool {
        let timestamp = Int(Date().timeIntervalSince1970)
        var components = URLComponents(string: "https://pan.baidu.com/share/verify")!
        components.percentEncodedQuery = "surl=\(surl)&t=\(timestamp)&" + baseQuery()

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("https://pan.baidu.com/share/init?surl=\(surl)",
                         forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = "pwd=\(code)".data(using: .utf8)

        let payload = try await http.json(request)
        let errno = payload["errno"] as? Int ?? -1
        if errno == 0 { return true }
        if errno == -9 { return false }
        if errno == 105 { throw PanResolveError.linkInvalid("分享已失效或被取消") }
        let message = payload["show_msg"] as? String ?? "errno \(errno)"
        throw PanResolveError.platform("提取码验证失败：\(message)")
    }

    /// bdstoken 是转存等写操作的必带令牌。
    /// 注意这个接口对 fields 敏感：只请求 bdstoken 会回 errno 2，
    /// 必须连同 sign/timestamp 一起请求才会正常返回。
    private func fetchBdToken(http: PanHTTP) async throws -> String {
        var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        components.percentEncodedQuery = "fields=%5B%22sign%22%2C%22timestamp%22%2C%22bdstoken%22%5D&" + baseQuery()

        var request = URLRequest(url: components.url!)
        request.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")

        let payload = try await http.json(request)
        let errno = payload["errno"] as? Int ?? -1
        if errno == -6 { throw PanResolveError.credentialExpired(.baidu) }

        if let result = payload["result"] as? [String: Any],
           let token = result["bdstoken"] as? String, !token.isEmpty {
            return token
        }
        throw PanResolveError.platform("未能取到百度网盘操作令牌（errno \(errno)）")
    }

    private struct Transferred {
        var fsID: String
        var path: String
        /// true = 网盘里本来就有，没有新写盘
        var reused: Bool
    }

    /// 转存到 /来自分享，返回新文件的 fs_id 与落地路径
    private func transfer(http: PanHTTP,
                          link: ParsedLink,
                          entry: PanShareEntry,
                          shareID: String,
                          uk: String,
                          bdstoken: String) async throws -> Transferred {
        guard !shareID.isEmpty, !uk.isEmpty else {
            throw PanResolveError.platform("分享信息不完整，缺少 shareid 或 uk")
        }

        let safeFolder = Prober.sanitize((entry.name as NSString).deletingPathExtension)
        let targetDir = "\(Self.transferRoot)/\(safeFolder)"
        let targetPath = "\(targetDir)/\(Prober.sanitize(entry.name))"

        // 幂等：网盘里已有同名同大小的文件时，百度 transfer 会直接回「文件已存在」
        // 且不给 fs_id，所以先自己搜一遍，命中就复用，避免重复往用户网盘写数据
        if let existing = try? await searchExisting(http: http,
                                                    name: entry.name,
                                                    size: entry.size) {
            return Transferred(fsID: existing.fsID, path: existing.path, reused: true)
        }
        _ = targetPath

        var components = URLComponents(string: "https://pan.baidu.com/share/transfer")!
        components.percentEncodedQuery = "shareid=\(shareID)&from=\(uk)&ondup=newcopy"
            + "&async=1&" + baseQuery() + "&bdstoken=\(bdstoken)"

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let url = link.url, let surl = PanLink.baiduSurl(from: url) {
            request.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")
        }

        let fsidlist = "%5B\(entry.id)%5D"
        // 注意 / 必须保留，用 alphanumerics 会把分隔符也编码掉，百度那边就当成了文件名
        let encodedPath = targetDir.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? targetDir
        request.httpBody = "fsidlist=\(fsidlist)&path=\(encodedPath)".data(using: .utf8)

        let payload = try await http.json(request)
        let errno = payload["errno"] as? Int ?? -1

        if errno == 0 || errno == 12 {
            // errno 12 = 部分文件已存在，仍然算成功
            if let extra = payload["extra"] as? [String: Any],
               let list = extra["list"] as? [[String: Any]],
               let first = list.first {
                let toPath = first["to"] as? String ?? targetDir
                let toFsID = (first["to_fsid"] as? NSNumber)?.stringValue
                    ?? (first["to_fsid"] as? String) ?? ""
                if !toFsID.isEmpty {
                    return Transferred(fsID: toFsID, path: toPath, reused: false)
                }
                // 没有 to_fsid 时按路径去查一次
                if let found = try await findFsID(http: http, path: toPath) {
                    return Transferred(fsID: found, path: toPath, reused: false)
                }
            }
            throw PanResolveError.platform("转存成功但没拿到文件标识，请稍后重试")
        }

        switch errno {
        case -6:
            throw PanResolveError.credentialExpired(.baidu)
        case 4:
            throw PanResolveError.platform("该分享不允许转存")
        case 12:
            throw PanResolveError.platform("转存冲突，请重试")
        case -33:
            throw PanResolveError.platform("你的百度网盘空间不足")
        default:
            let message = payload["show_msg"] as? String ?? "errno \(errno)"
            throw PanResolveError.platform("转存失败：\(message)")
        }
    }

    /// 在用户网盘里按文件名 + 大小找同内容文件。
    /// 命中说明之前转过或者本来就有，直接复用能省一次写盘，也避开「文件已存在」的报错。
    private func searchExisting(http: PanHTTP,
                                name: String,
                                size: Int64) async throws -> (fsID: String, path: String)? {
        let key = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let urlString = "https://pan.baidu.com/api/search"
            + "?key=\(key)&dir=%2F&recursion=1&page=1&num=50&order=time&desc=1"
            + "&web=1&app_id=\(Self.appID)&channel=chunlei&clienttype=0"

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")

        guard let payload = try? await http.json(request),
              (payload["errno"] as? Int ?? -1) == 0,
              let list = payload["list"] as? [[String: Any]] else { return nil }

        for item in list {
            guard (item["server_filename"] as? String) == name else { continue }
            let itemSize = (item["size"] as? NSNumber)?.int64Value
                ?? Int64(item["size"] as? String ?? "0") ?? 0
            // 同名但大小差得多，显然是另一个文件，不能复用
            if size > 0 && itemSize > 0 && itemSize != size { continue }
            guard let fsID = (item["fs_id"] as? NSNumber)?.stringValue
                ?? (item["fs_id"] as? String) else { continue }
            let path = (item["path"] as? String) ?? name
            return (fsID, path)
        }
        return nil
    }

    /// 按路径查 fs_id，转存接口偶尔不回 to_fsid
    private func findFsID(http: PanHTTP, path: String) async throws -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let encodedDir = dir.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dir

        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.percentEncodedQuery = "dir=\(encodedDir)&order=time&desc=1&showempty=0"
            + "&page=1&num=200&" + baseQuery()

        var request = URLRequest(url: components.url!)
        request.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")

        let payload = try await http.json(request)
        guard let list = payload["list"] as? [[String: Any]] else { return nil }
        for item in list where (item["server_filename"] as? String) == name {
            return (item["fs_id"] as? NSNumber)?.stringValue
                ?? (item["fs_id"] as? String)
        }
        return nil
    }

    /// 自己网盘里的文件才有可用的 dlink。
    ///
    /// 注意要用 `/rest/2.0/xpan/file?method=filemetas`，而不是 `/api/filemetas`：
    /// 后者对同样的 fs_id 一律回 errno 12 / info.errno 31021；
    /// 而且不要带空的 `access_token=` 参数，带了会回 9019 need verify。
    private func fetchDLink(http: PanHTTP, fsID: String, bdstoken: String) async throws -> URL {
        let urlString = "https://pan.baidu.com/rest/2.0/xpan/file"
            + "?method=filemetas&dlink=1&fsids=%5B\(fsID)%5D"
            + "&web=1&app_id=\(Self.appID)&channel=chunlei&clienttype=0&bdstoken=\(bdstoken)"

        guard let url = URL(string: urlString) else {
            throw PanResolveError.platform("直链请求地址构造失败")
        }
        var request = URLRequest(url: url)
        request.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")

        let payload = try await http.json(request)
        let errno = payload["errno"] as? Int ?? -1

        if errno == -6 { throw PanResolveError.credentialExpired(.baidu) }
        guard errno == 0 else {
            let message = payload["show_msg"] as? String ?? "errno \(errno)"
            throw PanResolveError.platform("取直链失败：\(message)")
        }

        guard let info = payload["info"] as? [[String: Any]], let first = info.first else {
            throw PanResolveError.platform("百度网盘没有返回文件信息")
        }
        if let inner = first["errno"] as? Int, inner != 0 {
            throw PanResolveError.platform("百度网盘拒绝提供直链（errno \(inner)）")
        }
        if let dlink = first["dlink"] as? String, let target = URL(string: dlink) {
            return target
        }
        throw PanResolveError.platform("百度网盘没有返回下载地址，可能是该文件需要会员权限")
    }

    // MARK: 清理

    /// 删除转存落地目录，避免长期占用用户网盘空间
    static func cleanTransferred(cookies: [String: String]) async {
        let http = PanHTTP(seed: cookies)
        var request = URLRequest(url: URL(string: "https://pan.baidu.com/api/gettemplatevariable?fields=%5B%22bdstoken%22%5D&channel=chunlei&web=1&app_id=250528&clienttype=0")!)
        request.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")
        guard let payload = try? await http.json(request),
              let result = payload["result"] as? [String: Any],
              let token = result["bdstoken"] as? String else { return }

        let encoded = transferRoot.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? transferRoot
        var components = URLComponents(string: "https://pan.baidu.com/api/filemanager")!
        components.percentEncodedQuery = "opera=delete&async=2&onnest=fail&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken=\(token)"

        var delete = URLRequest(url: components.url!)
        delete.httpMethod = "POST"
        delete.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                        forHTTPHeaderField: "Content-Type")
        delete.setValue("https://pan.baidu.com/disk/home", forHTTPHeaderField: "Referer")
        delete.httpBody = "filelist=%5B%22\(encoded)%22%5D".data(using: .utf8)
        _ = try? await http.send(delete)
    }
}
