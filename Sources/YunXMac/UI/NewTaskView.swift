import SwiftUI
import AppKit

struct NewTaskView: View {

    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings

    @State private var input: String = ""
    @State private var parsed: [ParsedLink] = []
    @State private var startedIDs: Set<UUID> = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editor
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
                    onDownload: { startDownload(link) },
                    onOpenBrowser: { openInBrowser(link) }
                )
            }
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("本版本可直接下载 HTTP / HTTPS 直链与 GitHub 文件链接", systemImage: "checkmark.seal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label("网盘分享页需要账号授权，先识别来源与提取码，可一键复制到浏览器", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label("磁力 / BT / eD2k 仅做识别，请交给专用下载工具", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: 行为

    private func startDownload(_ link: ParsedLink) {
        guard let url = link.url else { return }
        startedIDs.insert(link.id)
        Task {
            await manager.enqueue(url: url, provider: link.provider)
            NotificationCenter.default.post(name: .yunxNewTask, object: nil)
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
    var onDownload: () -> Void
    var onOpenBrowser: () -> Void

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

            VStack(spacing: 6) {
                if link.provider.isDownloadableInThisVersion {
                    Button(isStarted ? "已加入" : "下载") {
                        onDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isStarted)
                } else {
                    Button("浏览器打开") {
                        onOpenBrowser()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(width: 96)
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
        case .direct: return "可直接下载 · 支持分片并发与断点续传"
        case .share: return "需要账号授权，本版本先识别来源与提取码"
        case .media: return "视频平台作品页，需登录后解析"
        case .p2p: return "P2P 链接，请使用专用下载工具"
        case .unknown: return "未识别的来源，可尝试浏览器打开确认"
        }
    }

    private var capabilityColor: Color {
        switch link.provider.kind {
        case .direct: return Theme.success
        case .share, .media: return .secondary
        default: return .secondary
        }
    }
}
