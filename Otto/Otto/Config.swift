import Foundation

enum Config {
    private static let env = ProcessInfo.processInfo.environment

    static var openAIKey: String {
        env["OPENAI_API_KEY"] ?? SettingsStore.shared.openAIKey
    }
    static var model: String { env["OTTO_MODEL"] ?? "gpt-realtime-2" }
    static var userName: String? {
        let v = env["OTTO_USER_NAME"] ?? SettingsStore.shared.userName
        return v.isEmpty ? nil : v
    }
    static var micName: String? {
        let v = env["OTTO_MIC"] ?? SettingsStore.shared.micName
        return v.isEmpty ? nil : v
    }

    static var dataDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Otto")
    }
    static var bundleCapabilitiesURL: URL? {
        Bundle.main.url(forResource: "capabilities", withExtension: "json", subdirectory: "memory")
    }
    static var userCapabilitiesURL: URL {
        dataDir.appendingPathComponent("capabilities.user.json")
    }
    static var sessionsDir: URL {
        dataDir.appendingPathComponent("sessions")
    }
}
