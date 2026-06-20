import Observation

// MARK: - Shared data types (used by both PythonBridge and OttoEngine)

struct RecentPhrase: Equatable {
    let phrase: String
    let count: Int
}

struct LearnedEvent: Equatable {
    let id: String
    let action: String      // "new_capability" | "added_phrasing"
    let phrase: String
    let description: String
    let primitive: String
}

struct JournalHeader: Equatable {
    let capabilities: Int
    let learned: Int
    let commands: Int
}

struct JournalCard: Identifiable, Equatable {
    let id: String
    let description: String
    let examples: [String]
    let primitive: String
    let template: String
    let origin: String       // "learned" | "shipped"
    let learnedAt: String?
    let timesUsed: Int
    let lastUsed: String?
    let confidence: Double
}

// MARK: - Protocol

/// Common interface for both the Python IPC bridge (PythonBridge) and the
/// native Swift engine (OttoEngine). SwiftUI views bind to `any OttoBridge`.
/// Both conformers are @Observable reference types, so existential observation
/// tracking works on macOS 14+ via the Observable protocol witness table.
protocol OttoBridge: AnyObject, Observable {

    // MARK: Published state (read by SwiftUI views)
    var micLevel: Float { get set }
    var waveformActive: Bool { get set }
    var transcript: String { get set }
    var spokenText: String { get set }
    var isReady: Bool { get set }
    var lastError: String? { get set }
    var learnedEvent: LearnedEvent? { get set }
    var journalHeader: JournalHeader? { get set }
    var journalCards: [JournalCard] { get set }
    var recentPhrases: [RecentPhrase] { get set }

    // MARK: Commands
    func sendVoiceStart()
    func sendVoiceStop()
    func sendText(_ text: String)
    func requestJournal()
    func requestSuggestions()
    func undoLearning(_ id: String)
    func deleteCapability(_ id: String)
    func editCapability(_ id: String, description: String?, examples: [String]?)
}
