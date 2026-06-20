import Foundation
import Security
import ServiceManagement

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let keychainService = "com.otto.app"

    @Published var openAIKey: String = ""
    @Published var userName: String = ""
    @Published var micName: String = ""
    @Published var browserName: String = ""
    @Published var summonHotkey: HotkeyConfig = .summonDefault
    @Published var journalHotkey: HotkeyConfig = .journalDefault
    @Published var micAutoStart: Bool = true
    @Published var launchAtLogin: Bool = false

    var isConfigured: Bool {
        !openAIKey.isEmpty && UserDefaults.standard.bool(forKey: "otto.onboardingComplete")
    }

    private init() { reload() }

    func reload() {
        openAIKey   = keychainRead(account: "OPENAI_API_KEY") ?? ""
        userName    = UserDefaults.standard.string(forKey: "otto.userName") ?? ""
        micName     = UserDefaults.standard.string(forKey: "otto.micName") ?? ""
        browserName = UserDefaults.standard.string(forKey: "otto.browserName") ?? ""
        summonHotkey  = Self.decodeHotkey("otto.summonHotkey")  ?? .summonDefault
        journalHotkey = Self.decodeHotkey("otto.journalHotkey") ?? .journalDefault
        micAutoStart  = UserDefaults.standard.object(forKey: "otto.micAutoStart") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func save() {
        keychainWrite(account: "OPENAI_API_KEY", value: openAIKey)
        UserDefaults.standard.set(userName,    forKey: "otto.userName")
        UserDefaults.standard.set(micName,     forKey: "otto.micName")
        UserDefaults.standard.set(browserName, forKey: "otto.browserName")
        Self.encodeHotkey(summonHotkey,  forKey: "otto.summonHotkey")
        Self.encodeHotkey(journalHotkey, forKey: "otto.journalHotkey")
        UserDefaults.standard.set(micAutoStart, forKey: "otto.micAutoStart")
        UserDefaults.standard.set(true,        forKey: "otto.onboardingComplete")
        applyLaunchAtLogin(launchAtLogin)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // SMAppService errors are non-fatal; state is reflected on next reload()
        }
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

    // MARK: - Hotkey persistence (JSON in UserDefaults)

    private static func encodeHotkey(_ cfg: HotkeyConfig, forKey key: String) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func decodeHotkey(_ key: String) -> HotkeyConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }
}
