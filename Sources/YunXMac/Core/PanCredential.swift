import Foundation
import Security
import Combine

/// 一个网盘账号的登录态。
///
/// 只保存解析直链真正需要的 cookie，不保存密码——密码从来没有经过我们，
/// 是用户在系统内置的网页视图里直接登给平台自己的。
struct PanCredential: Codable, Identifiable {

    var provider: Provider
    /// 关键 cookie（百度 BDUSS/STOKEN，夸克 __puus 等）；其余 cookie 一并带上更稳
    var cookies: [String: String]
    var userAgent: String
    var savedAt: Date
    /// 能不能拿到昵称取决于平台接口，拿不到就显示平台名
    var accountName: String?

    var id: String { provider.rawValue }

    /// 拼成 Cookie 请求头的值
    var cookieHeader: String {
        cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }
}

/// 凭证存进钥匙串，不落 UserDefaults、不写明文文件。
enum PanCredentialStore {

    private static let service = "cn.yunxmac.pan-credential"

    static func load(provider: Provider) -> PanCredential? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PanCredential.self, from: data)
    }

    static func loadAll() -> [Provider: PanCredential] {
        var result: [Provider: PanCredential] = [:]
        for provider in Provider.allCases where provider.kind == .share {
            if let credential = load(provider: provider) {
                result[provider] = credential
            }
        }
        return result
    }

    @discardableResult
    static func save(_ credential: PanCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.provider.rawValue
        ]

        // 先删再写，避免 errSecDuplicateItem
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "YunX · \(credential.provider.displayName)"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func clear(provider: Provider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 凭证在内存里的单一入口，界面直接观察它。
@MainActor
final class PanAccountStore: ObservableObject {

    static let shared = PanAccountStore()

    /// provider -> 凭证
    @Published private(set) var credentials: [Provider: PanCredential] = [:]

    init() {
        credentials = PanCredentialStore.loadAll()
    }

    func credential(for provider: Provider) -> PanCredential? {
        credentials[provider]
    }

    func isSignedIn(_ provider: Provider) -> Bool {
        credentials[provider] != nil
    }

    func signIn(_ credential: PanCredential) {
        guard PanCredentialStore.save(credential) else { return }
        credentials[credential.provider] = credential
    }

    func signOut(_ provider: Provider) {
        PanCredentialStore.clear(provider: provider)
        credentials.removeValue(forKey: provider)
    }

    /// 解析时如果接口回「登录失效」，把这条凭证清掉，逼用户重登
    func invalidate(_ provider: Provider) {
        signOut(provider)
    }
}
