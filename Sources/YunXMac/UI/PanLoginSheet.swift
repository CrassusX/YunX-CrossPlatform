import SwiftUI
import WebKit

/// 网盘登录窗口：在应用内打开平台自己的登录页，用户正常登录一次，
/// 我们只把解析直链需要的会话 Cookie 存进钥匙串——密码永远不经过我们。
struct PanLoginSheet: View {

    let provider: Provider
    /// 登录成功回调；取消则传 nil
    var onFinish: (PanCredential?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: PanAccountStore

    @State private var status: Status = .waiting

    enum Status: Equatable {
        case waiting
        case detected
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            PanLoginWebView(provider: provider) { result in
                switch result {
                case .success(let credential):
                    status = .detected
                    accounts.signIn(credential)
                    // 给用户一点时间看到"已登录"再关窗，避免一闪而过
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onFinish(credential)
                        dismiss()
                    }
                case .failure(let error):
                    status = .failed(error.localizedDescription)
                }
            }

            Divider()

            footer
        }
        .frame(width: 900, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.warning.opacity(0.14))
                Image(systemName: provider.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.warning)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("登录\(provider.displayName)")
                    .font(.system(size: 14, weight: .semibold))
                Text("登录后会自动取到会话凭证，只保存在本机钥匙串，不上传任何服务器")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("等待登录…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .detected:
            Label("已登录", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(provider.loginHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button("取消") {
                onFinish(nil)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("清除本窗口登录状态") {
                WKWebsiteDataStore.default().removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: Date(timeIntervalSince1970: 0)
                ) {
                    status = .waiting
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - WKWebView 包装

private struct PanLoginWebView: NSViewRepresentable {

    let provider: Provider
    var onResult: (Result<PanCredential, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, onResult: onResult)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 用持久化数据仓库，第二次打开窗口时往往还是登录态
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.attach(webView)
        webView.load(URLRequest(url: provider.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {

        private let provider: Provider
        private let onResult: (Result<PanCredential, Error>) -> Void
        private var timer: Timer?
        private weak var webView: WKWebView?
        private var reported = false

        init(provider: Provider, onResult: @escaping (Result<PanCredential, Error>) -> Void) {
            self.provider = provider
            self.onResult = onResult
        }

        deinit { timer?.invalidate() }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            // Cookie 变化没有公用的通知，只能轮询；1 秒一次足够，代价可以忽略
            timer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.probeCookies()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func probeCookies() {
            guard !reported, let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.reported else { return }
                let relevant = cookies.filter { $0.domain.contains(self.provider.cookieDomainKeyword) }
                guard !relevant.isEmpty else { return }

                var map: [String: String] = [:]
                for cookie in relevant { map[cookie.name] = cookie.value }

                // 各家判断"真的登录了"的 cookie 不一样
                let signedIn = self.provider.loginCookieNames.contains { name in
                    (map[name]?.isEmpty == false)
                }
                guard signedIn else { return }

                self.reported = true
                self.timer?.invalidate()

                let credential = PanCredential(
                    provider: self.provider,
                    cookies: map,
                    userAgent: PanHTTP.userAgent,
                    savedAt: Date(),
                    accountName: self.provider.displayName
                )
                DispatchQueue.main.async {
                    self.onResult(.success(credential))
                }
            }
        }
    }
}

// MARK: - 各平台的登录参数

extension Provider {

    var loginURL: URL {
        switch self {
        case .baidu:
            return URL(string: "https://pan.baidu.com/")!
        case .quark:
            return URL(string: "https://pan.quark.cn/")!
        case .uc:
            return URL(string: "https://drive.uc.cn/")!
        default:
            return URL(string: "https://www.baidu.com/")!
        }
    }

    /// cookie 域名包含这个关键字才收
    var cookieDomainKeyword: String {
        switch self {
        case .baidu: return "baidu.com"
        case .quark: return "quark.cn"
        case .uc: return "uc.cn"
        default: return ""
        }
    }

    /// 出现其中任意一个，才认为用户真的登录了（而不是停在游客态）
    var loginCookieNames: [String] {
        switch self {
        case .baidu: return ["BDUSS", "BDUSS_BFESS", "STOKEN"]
        case .quark: return ["__puus", "__pus", "__kp"]
        case .uc: return ["__puus", "__pus"]
        default: return []
        }
    }

    var loginHint: String {
        switch self {
        case .baidu:
            return "在下方页面用扫码或账号密码登录百度网盘，登录成功后窗口会自动关闭"
        case .quark:
            return "在下方页面登录夸克网盘，登录成功后窗口会自动关闭"
        case .uc:
            return "在下方页面登录 UC 网盘，登录成功后窗口会自动关闭"
        default:
            return "在下方页面完成登录"
        }
    }
}
