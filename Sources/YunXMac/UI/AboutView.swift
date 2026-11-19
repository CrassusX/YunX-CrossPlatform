import SwiftUI
import AppKit

struct AboutView: View {

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var runningArch: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "未知架构"
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Theme.accent, Color(red: 0.24, green: 0.36, blue: 0.92)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text("云析 · macOS 版")
                        .font(.system(size: 18, weight: .semibold))
                    Text("YunX-Mac-Desktop  \(version) (\(build))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    SettingsCard(title: "运行环境", icon: "cpu") {
                        VStack(alignment: .leading, spacing: 6) {
                            row("架构", runningArch)
                            row("通用二进制", "同时包含 arm64 与 x86_64 切片，Apple 芯片与 Intel 芯片均可原生运行")
                            row("系统", ProcessInfo.processInfo.operatingSystemVersionString)
                            row("下载目录", DownloadManager.logDirectory.path)
                        }
                    }

                    SettingsCard(title: "能力", icon: "sparkles") {
                        VStack(alignment: .leading, spacing: 6) {
                            row("分片并发", "单任务多连接 Range 并行，慢连接自动重试")
                            row("断点续传", "分片进度实时落盘，退出应用后仍可续传")
                            row("全局限速", "基于时间片预约的精确限速，多任务共享总带宽")
                            row("镜像测速", "GitHub 下载前并发实测镜像，自动选最快")
                            row("链接识别", "自动识别网盘 / 视频平台来源并提取提取码")
                        }
                    }

                    SettingsCard(title: "开源与致谢", icon: "heart") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("本项目以 GNU AGPL-3.0 协议开源，灵感与功能形态参考 Windows 版 YunX-Desktop。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Button("参考项目") {
                                    NSWorkspace.shared.open(URL(string: "https://github.com/tidain/YunX-Desktop")!)
                                }
                                Button("源代码") {
                                    NSWorkspace.shared.open(URL(string: "https://github.com/CrassusX/YunX-CrossPlatform")!)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text("本软件仅供个人学习与合法用途，请遵守各平台服务条款，勿用于传播侵权内容。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .frame(width: 76, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }
}
