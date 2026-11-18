import Foundation

/// 夸克 / UC 网盘分享解析。
///
/// 两家是同一套接口（`/1/clouddrive/share/sharepage/*`），只有域名和 `pr` 渠道参数不同。
/// token 与 detail 两步未登录也能调，真正换直链的 download 需要登录态。
struct QuarkFamilyResolver: PanResolver {

    let provider: Provider

    /// 接口域名
    private var host: String {
        switch provider {
        case .uc: return "https://pc-api.uc.cn"
        default: return "https://drive-pc.quark.cn"
        }
    }

    /// 渠道参数，两家要求不同
    private var pr: String {
        provider == .uc ? "UCBrowser" : "ucpro"
    }

    private var fr: String {
        provider == .uc ? "pc" : "pc"
    }

    private var referer: String {
        provider == .uc ? "https://drive.uc.cn/" : "https://pan.quark.cn/"
    }

    private var commonQuery: String {
        "__dt=1000&__t=\(Int(Date().timeIntervalSince1970 * 1000))&pr=\(pr)&fr=\(fr)"
    }

    // MARK: 预览

    func preview(link: ParsedLink) async throws -> [PanShareEntry] {
        let http = PanHTTP()
        return try await detail(http: http, link: link)
    }

    // MARK: 解析

    func resolve(link: ParsedLink, credential: PanCredential) async throws -> ResolvedFile {
        let http = PanHTTP(seed: credential.cookies)
        let entries = try await detail(http: http, link: link)
        guard let target = entries.first(where: { !$0.isDirectory && $0.extraToken != nil }) else {
            throw PanResolveError.emptyShare
        }

        let downloadURL = try await fetchDownloadURL(http: http, link: link, entry: target)

        var headers = ["Referer": referer, "User-Agent": PanHTTP.userAgent]
        let cookieValue = http.allCookies()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        if !cookieValue.isEmpty { headers["Cookie"] = cookieValue }

        var note: String?
        let fileCount = entries.filter { !$0.isDirectory }.count
        if fileCount > 1 {
            note = "分享共 \(fileCount) 个文件，本次下载第 1 个：\(target.name)"
        }

        return ResolvedFile(
            url: downloadURL,
            fileName: target.name,
            size: target.size,
            headers: headers,
            provider: provider,
            note: note
        )
    }

    // MARK: 步骤

    /// 拿 stoken（带提取码的分享在这一步校验）
    private func fetchStoken(http: PanHTTP, link: ParsedLink) async throws -> (pwdID: String, stoken: String) {
        guard let url = link.url, let pwdID = PanLink.quarkPwdID(from: url) else {
            throw PanResolveError.linkInvalid("无法从链接里识别出\(provider.displayName)分享 ID")
        }

        var request = URLRequest(url: URL(string: "\(host)/1/clouddrive/share/sharepage/token?\(commonQuery)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(host, forHTTPHeaderField: "Origin")

        let body: [String: Any] = [
            "pwd_id": pwdID,
            "passcode": link.shareCode ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let payload = try await http.json(request)

        let code = (payload["code"] as? NSNumber)?.intValue ?? 0
        let status = (payload["status"] as? NSNumber)?.intValue ?? 200
        if status != 200 || code != 0 {
            let message = payload["message"] as? String ?? "code \(code)"
            // 41006 分享不存在 / 41001 提取码错误 是社区里最常撞到的两个
            if code == 41006 {
                throw PanResolveError.linkInvalid("\(provider.displayName)分享不存在或已失效")
            }
            if code == 41001 || code == 41009 {
                throw link.shareCode?.isEmpty == false
                    ? PanResolveError.platform("提取码不对：\(message)")
                    : PanResolveError.needPasscode(provider)
            }
            throw PanResolveError.platform("\(provider.displayName)返回：\(message)")
        }

        guard let data = payload["data"] as? [String: Any],
              let stoken = data["stoken"] as? String, !stoken.isEmpty else {
            throw PanResolveError.platform("未取到分享访问令牌")
        }
        return (pwdID, stoken)
    }

    private func detail(http: PanHTTP, link: ParsedLink) async throws -> [PanShareEntry] {
        let (pwdID, stoken) = try await fetchStoken(http: http, link: link)

        var components = URLComponents(
            string: "\(host)/1/clouddrive/share/sharepage/detail"
        )!
        components.percentEncodedQuery = "pwd_id=\(pwdID)&stoken=\(stoken)&pdir_fid=0&force=0"
            + "&_page=1&_size=100&_fetch_banner=0&_fetch_share=0&_fetch_total=1"
            + "&_sort=file_type:asc,updated_at:desc&" + commonQuery

        var request = URLRequest(url: components.url!)
        request.setValue(referer, forHTTPHeaderField: "Referer")

        let payload = try await http.json(request)
        let status = (payload["status"] as? NSNumber)?.intValue ?? 200
        guard status == 200 else {
            let message = payload["message"] as? String ?? "status \(status)"
            throw PanResolveError.platform("\(provider.displayName)返回：\(message)")
        }

        guard let data = payload["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else {
            throw PanResolveError.emptyShare
        }

        let entries: [PanShareEntry] = list.compactMap { item in
            guard let name = item["file_name"] as? String else { return nil }
            let isDir = (item["dir"] as? Bool) ?? ((item["file_type"] as? Int) == 0)
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            let fid = (item["fid"] as? String) ?? ""
            let token = (item["share_fid_token"] as? String) ?? (item["fid_token"] as? String)
            return PanShareEntry(name: name, size: size, isDirectory: isDir,
                                 id: fid, extraToken: token)
        }

        if entries.isEmpty { throw PanResolveError.emptyShare }
        return entries
    }

    private func fetchDownloadURL(http: PanHTTP, link: ParsedLink, entry: PanShareEntry) async throws -> URL {
        let (pwdID, stoken) = try await fetchStoken(http: http, link: link)

        var request = URLRequest(
            url: URL(string: "\(host)/1/clouddrive/share/sharepage/download?\(commonQuery)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(host, forHTTPHeaderField: "Origin")

        let body: [String: Any] = [
            "fid_list": [entry.id],
            "fid_token_list": [entry.extraToken ?? ""],
            "pwd_id": pwdID,
            "stoken": stoken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let payload = try await http.json(request)

        if let code = (payload["code"] as? NSNumber)?.intValue,
           code == 31001 || code == 31002 {
            throw PanResolveError.credentialExpired(provider)
        }

        guard let data = payload["data"] as? [[String: Any]],
              let first = data.first,
              let raw = first["download_url"] as? String,
              let url = URL(string: raw) else {
            let message = payload["message"] as? String ?? "未返回下载地址"
            throw PanResolveError.platform("\(provider.displayName)：\(message)")
        }
        return url
    }
}

// MARK: - 统一分发

enum PanResolverFactory {

    static func resolver(for provider: Provider) -> PanResolver? {
        switch provider {
        case .baidu: return BaiduPanResolver()
        case .quark, .uc: return QuarkFamilyResolver(provider: provider)
        default: return nil
        }
    }

    /// 该平台是否已经接入解析（决定卡片上有没有下载按钮）
    static func isSupported(_ provider: Provider) -> Bool {
        resolver(for: provider) != nil
    }
}
