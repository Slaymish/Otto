import Observation

// MARK: - Shared data types

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
