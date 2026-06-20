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

    // Use a local Ollama model for the retrospective instead of OpenAI.
    static var ollamaEnabled: Bool {
        if let v = env["OTTO_OLLAMA"] { return (v as NSString).boolValue }
        return SettingsStore.shared.ollamaEnabled
    }
    static var ollamaHost: String {
        let v = env["OTTO_OLLAMA_HOST"] ?? SettingsStore.shared.ollamaHost
        return v.isEmpty ? "http://localhost:11434" : v
    }
    static var ollamaModel: String {
        let v = env["OTTO_OLLAMA_MODEL"] ?? SettingsStore.shared.ollamaModel
        return v.isEmpty ? "llama3.1" : v
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
