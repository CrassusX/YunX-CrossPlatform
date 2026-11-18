import SwiftUI

struct DownloadListView: View {

    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manager.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.jobs) { job in
                            DownloadRow(job: job, onDelete: { deleteFiles in
                                manager.remove(job, deleteFiles: deleteFiles)
                            })
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("下载")
                    .font(.system(size: 17, weight: .semibold))
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                for job in manager.jobs where job.status == .running {
                    manager.pause(job)
                }
            } label: {
                Label("全部暂停", systemImage: "pause.fill")
            }
            .disabled(!manager.jobs.contains { $0.status == .running })

            Button {
                for job in manager.jobs where job.status == .paused || job.status == .failed {
                    manager.resume(job)
                }
            } label: {
                Label("全部继续", systemImage: "play.fill")
            }
            .disabled(!manager.jobs.contains { $0.status == .paused || $0.status == .failed })
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var summaryText: String {
        let running = manager.jobs.filter { $0.status == .running }.count
        let totalSpeed = manager.jobs.reduce(0.0) { $0 + $1.speed }
        if running > 0 {
            return "\(running) 个任务进行中 · 合计 \(Fmt.speed(totalSpeed))"
        }
        return manager.jobs.isEmpty ? "还没有任务" : "共 \(manager.jobs.count) 个任务"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("粘贴链接开始下载")
                .font(.title3.weight(.medium))
            Text("支持 HTTP / HTTPS 直链与 GitHub 文件链接\n分片并发 + 断点续传 + 全局限速")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("新建任务") {
                NotificationCenter.default.post(name: .yunxNewTask, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单行

struct DownloadRow: View {

    @ObservedObject var job: DownloadJob
    @EnvironmentObject private var manager: DownloadManager

    var onDelete: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconBadge

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(job.record.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusBadge
                    Spacer(minLength: 0)
                }

                progressBar

                HStack(spacing: 6) {
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            actionButtons
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if job.status == .completed { manager.open(job) }
        }
        .contextMenu {
            if job.status == .running {
                Button("暂停") { manager.pause(job) }
            }
            if job.status == .paused || job.status == .failed {
                Button("继续") { manager.resume(job) }
            }
            Button("在 Finder 中显示") { manager.reveal(job) }
            if job.status == .completed {
                Button("打开文件") { manager.open(job) }
            }
            Divider()
            Button("移除任务") { onDelete(false) }
            Button("移除并删除文件", role: .destructive) { onDelete(true) }
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(badgeColor.opacity(0.14))
            Image(systemName: job.record.provider.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(badgeColor)
        }
        .frame(width: 34, height: 34)
    }

    private var badgeColor: Color {
        switch job.status {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .paused: return Theme.warning
        case .cancelled: return .secondary
        default: return Theme.accent
        }
    }

    private var statusBadge: some View {
        Text(job.isPreparing ? "解析中" : job.status.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeColor.opacity(0.12)))
    }

    private var progressBar: some View {
        BarProgressView(
            value: job.total > 0 ? min(1, max(0, job.progress)) : 0,
            tint: badgeColor,
            indeterminate: job.total <= 0 && job.status == .running
        )
        .frame(height: 5)
    }

    private var detailText: String {
        if job.isPreparing { return "正在读取文件信息…" }

        if job.status == .failed {
            if let error = job.errorMessage ?? job.record.errorMessage, !error.isEmpty {
                return error
            }
            return "下载失败"
        }

        switch job.status {
        case .running:
            let parts = [
                Fmt.speed(job.speed),
                "已下载 \(Fmt.bytes(job.received))" + (job.total > 0 ? " / \(Fmt.bytes(job.total))" : ""),
                job.etaSeconds.isFinite && job.etaSeconds < 86_400
                    ? "剩余 \(Fmt.eta(job.etaSeconds))" : nil
            ].compactMap { $0 }
            return parts.joined(separator: "  ·  ")
        case .completed:
            let size = job.total > 0 ? Fmt.bytes(job.total) : Fmt.bytes(job.received)
            return "\(size)  ·  \(job.record.directoryPath)"
        case .paused:
            return "已暂停  ·  \(Fmt.bytes(job.received))"
                + (job.total > 0 ? " / \(Fmt.bytes(job.total))" : "")
        case .queued:
            return job.total > 0 ? "等待中  ·  \(Fmt.bytes(job.total))" : "等待中"
        case .cancelled:
            return "已取消"
        case .failed:
            return "下载失败"
        }
    }

    private var detailColor: Color {
        job.status == .failed ? Theme.danger : Color.secondary
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if job.status == .running {
                Button {
                    manager.pause(job)
                } label: {
                    Image(systemName: "pause.fill")
                }
                .help("暂停")
            } else if job.status == .paused || job.status == .failed {
                Button {
                    manager.resume(job)
                } label: {
                    Image(systemName: "play.fill")
                }
                .help("继续")
            } else if job.status == .completed {
                Button {
                    manager.open(job)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("打开文件")
            }

            Button {
                manager.reveal(job)
            } label: {
                Image(systemName: "folder")
            }
            .help("在 Finder 中显示")

            Menu {
                Button("移除任务") { onDelete(false) }
                Button("移除并删除文件", role: .destructive) { onDelete(true) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 12))
    }
}


/// 自绘进度条：系统的 linear ProgressView 在 macOS 26 上 tint 表现不稳定，
/// 暂停态用橙色会被渲染成淡紫灰，这里直接用 Capsule 拼，颜色完全可控。
struct BarProgressView: View {

    var value: Double
    var tint: Color
    var indeterminate: Bool = false

    @State private var scanOffset: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                if indeterminate {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(24, width * 0.28))
                        .offset(x: scanOffset * width)
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                                   value: scanOffset)
                        .onAppear { scanOffset = 0.98 }
                } else if value > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, width * CGFloat(min(1, max(0, value)))))
                        .animation(.easeOut(duration: 0.25), value: value)
                }
            }
            .frame(height: height)
        }
    }
}
