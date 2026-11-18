import Foundation
import UserNotifications

/// 完成/失败通知。未打包成 .app 直接跑二进制时没有 bundle id，
/// 此时静默降级，不影响主流程。
enum Notifier {

    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func completed(fileName: String) {
        post(title: "下载完成", body: fileName)
    }

    static func failed(fileName: String, reason: String) {
        post(title: "下载失败", body: "\(fileName)\n\(reason)")
    }

    private static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
