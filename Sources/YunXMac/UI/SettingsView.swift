import SwiftUI
import AppKit

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings

    @State private var mirrorResults: [MirrorResult] = []
    @State private var isTesting = false
    @State private var customPrefix: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                    Text("改动立即生效并自动保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    storageSection
                    concurrencySection
                    behaviorSection
                    mirrorSection
                }
                .padding(18)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            customPrefix = settings.mirrorPrefix
            if mirrorResults.isEmpty { runMirrorTest() }
        }
    }

    // MARK: 存储

    private var storageSection: some View {
        SettingsCard(title: "存储", icon: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(settings.downloadDirectory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                        )

                    Button("选择…") { chooseDirectory() }
                        .controlSize(.small)
                    Button("打开") {
                        settings.ensureDirectoryExists()
                        NSWorkspace.shared.selectFile(nil,
                            inFileViewerRootedAtPath: settings.downloadDirectory)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url.path
            settings.ensureDirectoryExists()
        }
    }

    // MARK: 并发与限速

    private var concurrencySection: some View {
        SettingsCard(title: "下载", icon: "speedometer") {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: $settings.maxConcurrentTasks, in: 1...8) {
                    HStack {
                        Text("同时下载任务数")
                        Spacer()
                        Text("\(settings.maxConcurrentTasks)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: $settings.connectionsPerTask, in: 1...32) {
                    HStack {
                        Text("单任务分片并发")
                        Spacer()
                        Text("\(settings.connectionsPerTask)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text("全局限速")
                    Spacer()
                    Picker("", selection: $settings.speedLimitKBps) {
                        Text("不限速").tag(0)
                        Text("500 KB/s").tag(500)
                        Text("1 MB/s").tag(1024)
                        Text("2 MB/s").tag(2048)
                        Text("5 MB/s").tag(5120)
                        Text("10 MB/s").tag(10240)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Text("分片数越多对服务器压力越大，公共站点建议 4–8；限速是全局总量，不会按任务叠加。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 行为

    private var behaviorSection: some View {
        SettingsCard(title: "行为", icon: "switch.2") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("下载完成时发送系统通知", isOn: $settings.notifyOnComplete)
                Toggle("打开界面时自动读取剪贴板中的链接", isOn: $settings.watchClipboard)
            }
        }
    }

    // MARK: 镜像

    private var mirrorSection: some View {
        SettingsCard(title: "GitHub 下载镜像", icon: "network") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("下载 GitHub 文件时走镜像加速", isOn: $settings.mirrorEnabled)

                HStack(spacing: 8) {
                    Text("当前使用")
                        .foregroundStyle(.secondary)
                    Text(currentMirrorLabel)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button {
                        runMirrorTest()
                    } label: {
                        Label(isTesting ? "测速中…" : "重新测速", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(isTesting)
                }

                if isTesting && mirrorResults.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在并发实测各镜像的延迟与吞吐…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(mirrorResults) { result in
                        mirrorRow(result)
                        if result.id != mirrorResults.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    TextField("自定义前缀，例如 https://ghfast.top", text: $customPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("应用") {
                        settings.mirrorPrefix = MirrorTester.normalize(customPrefix)
                    }
                    .controlSize(.small)
                    Button("恢复自动") {
                        settings.mirrorPrefix = ""
                        customPrefix = ""
                        if let best = mirrorResults.first(where: { $0.isUsable }) {
                            settings.lastMirrorWinner = best.prefix
                        }
                    }
                    .controlSize(.small)
                }

                Text("测速结果只反映当下网络状况，镜像可用性会变化；下载失败时可在任务上重试或换镜像。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentMirrorLabel: String {
        if !settings.mirrorPrefix.isEmpty { return settings.mirrorPrefix }
        if !settings.lastMirrorWinner.isEmpty { return "自动 · \(URL(string: settings.lastMirrorWinner)?.host ?? settings.lastMirrorWinner)" }
        return "自动（尚未测速）"
    }

    private func mirrorRow(_ result: MirrorResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected(result) ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected(result) ? Theme.accent : Color.secondary.opacity(0.5))
                .font(.system(size: 11))

            Text(URL(string: result.prefix)?.host ?? result.prefix)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            if let error = result.errorText {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            } else {
                if let latency = result.latencyMs {
                    Text("\(Int(latency)) ms")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                if let speed = result.bytesPerSecond {
                    Text(Fmt.speed(speed))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.success)
                        .frame(width: 84, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard result.isUsable else { return }
            settings.mirrorPrefix = result.prefix
            customPrefix = result.prefix
        }
    }

    private func selected(_ result: MirrorResult) -> Bool {
        if !settings.mirrorPrefix.isEmpty { return settings.mirrorPrefix == result.prefix }
        return settings.lastMirrorWinner == result.prefix
    }

    private func runMirrorTest() {
        guard !isTesting else { return }
        isTesting = true
        mirrorResults = []

        let prefixes = settings.mirrorCandidates
        Task {
            let results = await MirrorTester.test(prefixes: prefixes)
            await MainActor.run {
                mirrorResults = results
                isTesting = false
                if settings.mirrorPrefix.isEmpty,
                   let best = results.first(where: { $0.isUsable }) {
                    settings.lastMirrorWinner = best.prefix
                }
            }
        }
    }
}

// MARK: - 卡片容器

struct SettingsCard<Content: View>: View {

    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content
                .font(.system(size: 12))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}
