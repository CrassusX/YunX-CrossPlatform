import SwiftUI

@main
struct YunXMacApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var manager: DownloadManager
    @StateObject private var accounts: PanAccountStore

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: DownloadManager(settings: settings))
        _accounts = StateObject(wrappedValue: PanAccountStore.shared)
        Notifier.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(settings)
                .environmentObject(manager)
                .environmentObject(accounts)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建下载任务") {
                    NotificationCenter.default.post(name: .yunxNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("暂停全部任务") {
                    NotificationCenter.default.post(name: .yunxPauseAll, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let yunxNewTask = Notification.Name("cn.yunxmac.newTask")
    static let yunxShowDownloads = Notification.Name("cn.yunxmac.showDownloads")
    static let yunxPauseAll = Notification.Name("cn.yunxmac.pauseAll")
}

/// 全局配色：主色沿用参考项目的蓝色，其余全部走系统语义色，自动适配深浅色
enum Theme {
    static let accent = Color(red: 0.298, green: 0.549, blue: 0.961)
    static let success = Color(red: 0.235, green: 0.686, blue: 0.404)
    static let warning = Color(red: 0.949, green: 0.639, blue: 0.216)
    static let danger = Color(red: 0.906, green: 0.318, blue: 0.318)
}
