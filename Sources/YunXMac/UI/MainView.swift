import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case downloads
    case newTask
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: return "下载"
        case .newTask: return "新建任务"
        case .settings: return "设置"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .downloads: return "arrow.down.circle"
        case .newTask: return "plus.circle"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct MainView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: DownloadManager

    @State private var selection: SidebarItem = .downloads

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label {
                    HStack {
                        Text(item.title)
                        if item == .downloads, activeCount > 0 {
                            Spacer()
                            Text("\(activeCount)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                    }
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item == .downloads ? Theme.accent : Color.secondary)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            Group {
                switch selection {
                case .downloads:
                    DownloadListView()
                case .newTask:
                    NewTaskView()
                case .settings:
                    SettingsView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .yunxNewTask)) { _ in
            selection = .newTask
        }
        .onReceive(NotificationCenter.default.publisher(for: .yunxShowDownloads)) { _ in
            selection = .downloads
        }
        .onReceive(NotificationCenter.default.publisher(for: .yunxPauseAll)) { _ in
            for job in manager.jobs where job.status == .running {
                manager.pause(job)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            manager.shutdown()
        }
    }

    private var activeCount: Int {
        manager.jobs.filter { $0.status == .running || $0.status == .queued }.count
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: settings.speedLimitKBps > 0 ? "tortoise" : "hare")
                .font(.caption2)
            Text(settings.speedLimitKBps > 0
                 ? "限速 \(settings.speedLimitKBps) KB/s"
                 : "不限速")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
