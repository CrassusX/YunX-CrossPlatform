import SwiftUI
import AppKit

struct NewTaskView: View {

    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var accounts: PanAccountStore

    @State private var input: String = ""
    @State private var parsed: [ParsedLink] = []
    @State private var startedIDs: Set<UUID> = []
    @State private var resolvingIDs: Set<UUID> = []
    @State private var isDropTargeted = false

    /// 要弹登录窗的平台
    @State private var loginProvider: Provider?
    /// 登录成功后要继续解析的那条链接
    @State private var pendingLink: ParsedLink?
    /// 顶部提示条
    @State private var banner: Banner?

    struct Banner: Identifiable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editor
                    if let banner {
                        bannerView(banner)
                    }
                    if !parsed.isEmpty { results }
                    hint
                }
                .padding(18)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: input) { _ in
            parsed = LinkParser.parse(text: input)
            startedIDs.removeAll()
        }
        .onAppear(perform: fillFromClipboardIfEmpty)
        .sheet(item: $loginProvider) { provider in
            PanLoginSheet(provider: provider) { credential in
                loginProvider = nil
                guard credential != nil, let link = pendingLink else {
                    pendingLink = nil
                    return
                }
                pendingLink = nil
                resolveAndEnqueue(link)
            }
            .environmentObject(accounts)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("新建任务")
                    .font(.system(size: 17, weight: .semibold))
                Text("粘贴链接，自动识别来源与提取码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settings.ensureDirectoryExists()
                NSWorkspace.shared.selectFile(nil,
                    inFileViewerRootedAtPath: settings.downloadDirectory)
            } label: {
                Label("打开下载目录", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: 输入框

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 116)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isDropTargeted ? Theme.accent : Color.secondary.opacity(0.25),
                                          lineWidth: isDropTargeted ? 2 : 1)
                    )

                if input.isEmpty {
                    Text("把分享链接、直链或整段分享文案粘到这里（可含提取码）")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.plainText, .url], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            HStack(spacing: 8) {
                Button {
                    if let string = NSPasteboard.general.string(forType: .string) {
                        input = string
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                Button {
                    input = ""
                    parsed = []
                } label: {
                    Label("清空", systemImage: "xmark")
                }
                .disabled(input.isEmpty)

                Spacer()

                Text(settings.downloadDirectory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: 提示条

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError
                  ? "exclamationmark.triangle.fill"
                  : "info.circle.fill")
                .foregroundStyle(banner.isError ? Theme.danger : Theme.accent)
                .font(.system(size: 12))
            Text(banner.message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                self.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((banner.isError ? Theme.danger : Theme.accent).opacity(0.10))
        )
    }

    // MARK: 解析结果

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别结果 · \(parsed.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(parsed) { link in
                LinkResultCard(
                    link: link,
                    isStarted: startedIDs.contains(link.id),
                    isResolving: resolvingIDs.contains(link.id),
                    isSignedIn: accounts.isSignedIn(link.provider),
                    onDownload: { startDownload(link) },
                    onOpenBrowser: { openInBrowser(link) },
                    onSignIn: {
                        pendingLink = link
                        loginProvider = link.provider
                    }
                )
            }
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("HTTP / HTTPS 直链与 GitHub 文件链接可直接下载，支持分片并发与断点续传",
                  systemImage: "checkmark.seal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label("百度网盘登录一次后即可直接下载分享文件（含子目录整树递归，多文件自动按目录结构建任务）",
                  systemImage: "person.badge.key")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label("夸克 / UC 已接入同一套解析逻辑，尚未逐一真机验证；其它网盘与视频平台暂只识别来源",
                  systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label("磁力 / BT / eD2k 仅做识别，请交给专用下载工具",
                  systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: 行为

    private func startDownload(_ link: ParsedLink) {
        banner = nil

        // 直链：不需要任何凭证，直接探测入队
        if link.provider.kind == .direct {
            guard let url = link.url else { return }
            startedIDs.insert(link.id)
            Task {
                await manager.enqueue(url: url, provider: link.provider)
                showDownloads()
            }
            return
        }

        // 网盘：已接入解析的三家走「登录 → 解析 → 入队」
        if PanResolverFactory.isSupported(link.provider) {
            if accounts.isSignedIn(link.provider) {
                resolveAndEnqueue(link)
            } else {
                pendingLink = link
                loginProvider = link.provider
            }
            return
        }

        // 视频平台 / 未接入的网盘：说清楚为什么不能下，而不是给个假按钮
        switch link.provider.kind {
        case .media:
            banner = Banner(
                message: "\(link.provider.displayName)作品页需要平台登录态与视频地址解析，本版本尚未接入。可以先用浏览器打开。",
                isError: false
            )
        case .p2p:
            banner = Banner(message: "磁力 / BT / eD2k 需要 P2P 引擎，本版本不提供下载。", isError: false)
        case .share:
            banner = Banner(
                message: "\(link.provider.displayName)暂未接入解析，目前支持百度、夸克、UC 三家。",
                isError: false
            )
        default:
            banner = Banner(message: "这个来源无法直接下载。", isError: false)
        }
    }

    private func resolveAndEnqueue(_ link: ParsedLink) {
        guard let resolver = PanResolverFactory.resolver(for: link.provider),
              let credential = accounts.credential(for: link.provider) else {
            pendingLink = link
            loginProvider = link.provider
            return
        }

        resolvingIDs.insert(link.id)
        Task {
            do {
                let files = try await resolver.resolveAll(link: link, credential: credential)
                for file in files {
                    await manager.enqueue(url: file.url,
                                          provider: file.provider,
                                          preferredName: file.fileName,
                                          extraHeaders: file.headers,
                                          knownSize: file.size,
                                          relativePath: file.relativePath)
                }
                startedIDs.insert(link.id)
                let note: String
                if files.count > 1 {
                    note = "已加入 \(files.count) 个文件（保持目录结构），任务队列里逐个下载"
                } else if let detail = files.first?.note {
                    note = detail
                } else {
                    note = "任务已加入队列"
                }
                banner = Banner(message: note, isError: false)
                showDownloads()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription

                // 凭证失效就清掉，下次点击会重新弹登录
                if let resolveError = error as? PanResolveError,
                   case .credentialExpired(let provider) = resolveError {
                    accounts.invalidate(provider)
                    banner = Banner(message: message + "，点下载可重新登录。", isError: true)
                } else {
                    banner = Banner(message: message, isError: true)
                }
            }
            resolvingIDs.remove(link.id)
        }
    }

    private func showDownloads() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            NotificationCenter.default.post(name: .yunxShowDownloads, object: nil)
        }
    }

    private func openInBrowser(_ link: ParsedLink) {
        guard let url = link.url else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let code = link.shareCode, link.provider.kind == .share {
            var items = components?.queryItems ?? []
            if !items.contains(where: { $0.name == "pwd" }) {
                items.append(URLQueryItem(name: "pwd", value: code))
            }
            components?.queryItems = items
        }
        if let target = components?.url {
            NSWorkspace.shared.open(target)
        }
    }

    private func fillFromClipboardIfEmpty() {
        guard input.isEmpty else { return }
        guard let string = NSPasteboard.general.string(forType: .string),
              !string.isEmpty else { return }
        if LinkParser.parseFirst(text: string) != nil {
            input = string
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? NSString else { return }
                DispatchQueue.main.async { input = text as String }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else { return }
                DispatchQueue.main.async { input = url.absoluteString ?? "" }
            }
            return true
        }
        return false
    }
}

// MARK: - 单个识别结果

struct LinkResultCard: View {

    let link: ParsedLink
    let isStarted: Bool
    let isResolving: Bool
    let isSignedIn: Bool

    var onDownload: () -> Void
    var onOpenBrowser: () -> Void
    var onSignIn: () -> Void

    private var canResolve: Bool {
        PanResolverFactory.isSupported(link.provider)
    }

    private var isDownloadable: Bool {
        link.provider.kind == .direct || canResolve
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(0.14))
                Image(systemName: link.provider.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(link.provider.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if let code = link.shareCode {
                        Text("提取码 \(code)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.warning.opacity(0.16)))
                            .foregroundStyle(Theme.warning)
                    }
                    if canResolve && !isSignedIn {
                        Text("需登录")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text(link.raw)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(capabilityText)
                    .font(.system(size: 10))
                    .foregroundStyle(capabilityColor)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if isDownloadable {
                    Button {
                        if canResolve && !isSignedIn { onSignIn() } else { onDownload() }
                    } label: {
                        if isResolving {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("解析中")
                            }
                        } else if isStarted {
                            Label("已加入", systemImage: "checkmark")
                        } else if canResolve && !isSignedIn {
                            Label("登录并下载", systemImage: "person.badge.key")
                        } else {
                            Label("下载", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isStarted || isResolving)
                } else {
                    Button("浏览器打开") {
                        onOpenBrowser()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // 可下载的卡片也保留浏览器入口，提取码会一并带上
                if isDownloadable {
                    Button("浏览器打开") {
                        onOpenBrowser()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 112)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var color: Color {
        switch link.provider.kind {
        case .direct: return Theme.accent
        case .share: return Theme.warning
        case .media: return Color(red: 0.62, green: 0.42, blue: 0.92)
        case .p2p: return Color(red: 0.35, green: 0.68, blue: 0.72)
        case .unknown: return .secondary
        }
    }

    private var capabilityText: String {
        switch link.provider.kind {
        case .direct:
            return "可直接下载 · 支持分片并发与断点续传"
        case .share:
            if canResolve {
                return isSignedIn
                    ? "已登录 · 可解析分享直链并下载"
                    : "登录一次后即可解析分享直链并下载"
            }
            return "需要账号授权，本版本先识别来源与提取码"
        case .media:
            return "视频平台作品页，暂未接入解析"
        case .p2p:
            return "P2P 链接，请使用专用下载工具"
        case .unknown:
            return "未识别的来源，可尝试浏览器打开确认"
        }
    }

    private var capabilityColor: Color {
        switch link.provider.kind {
        case .direct: return Theme.success
        case .share where canResolve: return isSignedIn ? Theme.success : .secondary
        default: return .secondary
        }
    }
}
