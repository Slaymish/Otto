import Foundation
import Security

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let keychainService = "com.otto.app"

    @Published var openAIKey: String = ""
    @Published var userName: String = ""
    @Published var micName: String = ""
    @Published var browserName: String = ""

    var isConfigured: Bool {
        !openAIKey.isEmpty && UserDefaults.standard.bool(forKey: "otto.onboardingComplete")
    }

    private init() { reload() }

    func reload() {
        openAIKey   = keychainRead(account: "OPENAI_API_KEY") ?? ""
        userName    = UserDefaults.standard.string(forKey: "otto.userName") ?? ""
        micName     = UserDefaults.standard.string(forKey: "otto.micName") ?? ""
        browserName = UserDefaults.standard.string(forKey: "otto.browserName") ?? ""
    }

    func save() {
        keychainWrite(account: "OPENAI_API_KEY", value: openAIKey)
        UserDefaults.standard.set(userName,    forKey: "otto.userName")
        UserDefaults.standard.set(micName,     forKey: "otto.micName")
        UserDefaults.standard.set(browserName, forKey: "otto.browserName")
        UserDefaults.standard.set(true,        forKey: "otto.onboardingComplete")
    }

    /// Env vars to inject into the Python subprocess.
    func asEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        if !openAIKey.isEmpty   { env["OPENAI_API_KEY"]  = openAIKey }
        if !userName.isEmpty    { env["OTTO_USER_NAME"]  = userName }
        if !micName.isEmpty     { env["OTTO_MIC"]        = micName }
        if !browserName.isEmpty { env["OTTO_BROWSER"]    = browserName }
        return env
    }

    // MARK: - Keychain

    private func keychainRead(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(account: String, value: String) {
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService,
            kSecAttrAccount:      account,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
