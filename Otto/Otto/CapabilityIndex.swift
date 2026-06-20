import Foundation
import NaturalLanguage

// MARK: - Capability model

struct Capability: Codable, Identifiable {
    let id: String
    var description: String
    var examples: [String]
    let primitive: String
    var template: String
    var origin: String
    var learnedAt: String?
    var timesUsed: Int
    var lastUsed: String?
    var confidence: Double
    var requiredApps: [String]?

    enum CodingKeys: String, CodingKey {
        case id, description, examples, primitive, template, origin
        case learnedAt = "learned_at"
        case timesUsed = "times_used"
        case lastUsed  = "last_used"
        case confidence
        case requiredApps = "required_apps"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        description = try c.decode(String.self, forKey: .description)
        examples    = try c.decode([String].self, forKey: .examples)
        primitive   = try c.decode(String.self, forKey: .primitive)
        template    = try c.decode(String.self, forKey: .template)
        origin      = try c.decodeIfPresent(String.self, forKey: .origin) ?? "shipped"
        learnedAt   = try c.decodeIfPresent(String.self, forKey: .learnedAt)
        timesUsed   = try c.decodeIfPresent(Int.self,    forKey: .timesUsed) ?? 0
        lastUsed    = try c.decodeIfPresent(String.self, forKey: .lastUsed)
        confidence  = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        requiredApps = try c.decodeIfPresent([String].self, forKey: .requiredApps)
    }
}

// MARK: - Index

@MainActor
final class CapabilityIndex {
    static let shared = CapabilityIndex()

    // Semantic match counts only above this cosine similarity. Keeps unrelated
    // queries returning nothing so the "no capability matched" signal stays
    // meaningful for retrospective learning.
    private static let semanticThreshold = 0.45

    private var capabilities: [Capability] = []

    // Cached sentence embeddings per capability id (description + each example).
    // nil when the OS sentence-embedding model is unavailable → pure keyword fallback.
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var vectors: [String: [[Double]]] = [:]

    private init() { reload() }

    func reload() {
        var caps: [Capability] = []

        if let url  = Config.bundleCapabilitiesURL,
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Capability].self, from: data) {
            caps = list
        }

        if let data = try? Data(contentsOf: Config.userCapabilitiesURL),
           let user = try? JSONDecoder().decode([Capability].self, from: data) {
            for u in user {
                if let i = caps.firstIndex(where: { $0.id == u.id }) {
                    caps[i] = u
                } else {
                    caps.append(u)
                }
            }
        }

        capabilities = caps
        buildVectors()
    }

    private func buildVectors() {
        guard let embedding else { vectors = [:]; return }
        var map: [String: [[Double]]] = [:]
        for cap in capabilities {
            map[cap.id] = ([cap.description] + cap.examples)
                .compactMap { embedding.vector(for: $0.lowercased()) }
        }
        vectors = map
    }

    // MARK: - Hybrid keyword + semantic search

    func retrieve(query: String, topK: Int = 3) -> [Capability] {
        let qToks = tokens(query)
        guard !qToks.isEmpty else { return [] }
        let qVec = embedding?.vector(for: query.lowercased())

        return capabilities
            .map { cap -> (Capability, Double) in
                let text = ([cap.description] + cap.examples).joined(separator: " ")
                let cToks = tokens(text)
                let overlap = Double(qToks.intersection(cToks).count)
                let jaccard = overlap / Double(qToks.union(cToks).count)
                let semantic = semanticScore(qVec: qVec, capID: cap.id)

                // Include on any lexical overlap (legacy behaviour) or a confident
                // semantic match; rank by whichever signal is stronger.
                let include = jaccard > 0 || semantic >= Self.semanticThreshold
                return (cap, include ? max(jaccard, semantic) : 0)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    func contextBlock(for query: String) -> String {
        contextBlock(for: retrieve(query: query))
    }

    func contextBlock(for caps: [Capability]) -> String {
        guard !caps.isEmpty else { return "" }
        var lines = ["RETRIEVED CAPABILITIES (use these as recipes):"]
        for cap in caps {
            lines.append("- \(cap.description)")
            lines.append("  primitive: \(cap.primitive)")
            let tpl = String(cap.template.prefix(120))
            lines.append("  template: \(tpl)")
        }
        return lines.joined(separator: "\n")
    }

    private func semanticScore(qVec: [Double]?, capID: String) -> Double {
        guard let qVec, let vecs = vectors[capID] else { return 0 }
        return vecs.reduce(0.0) { max($0, cosine(qVec, $1)) }
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return max(0, dot / (na.squareRoot() * nb.squareRoot()))
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    // MARK: - Journal data

    var all: [Capability] { capabilities }

    var header: JournalHeader {
        let learned = capabilities.filter { $0.origin == "learned" }.count
        return JournalHeader(capabilities: capabilities.count, learned: learned, commands: 0)
    }

    func asJournalCards() -> [JournalCard] {
        capabilities.map { c in
            JournalCard(
                id: c.id,
                description: c.description,
                examples: c.examples,
                primitive: c.primitive,
                template: c.template,
                origin: c.origin,
                learnedAt: c.learnedAt,
                timesUsed: c.timesUsed,
                lastUsed: c.lastUsed,
                confidence: c.confidence
            )
        }
    }

    // MARK: - CRUD (persists learned capabilities only)

    func delete(_ id: String) {
        capabilities.removeAll { $0.id == id }
        saveUserCapabilities()
    }

    func edit(_ id: String, description: String?, examples: [String]?) {
        guard let i = capabilities.firstIndex(where: { $0.id == id }) else { return }
        if let d = description { capabilities[i].description = d }
        if let e = examples    { capabilities[i].examples    = e }
        saveUserCapabilities()
    }

    func append(_ cap: Capability) {
        if let i = capabilities.firstIndex(where: { $0.id == cap.id }) {
            capabilities[i] = cap
        } else {
            capabilities.append(cap)
        }
        saveUserCapabilities()
    }

    private func saveUserCapabilities() {
        let learned = capabilities.filter { $0.origin == "learned" }
        guard let data = try? JSONEncoder().encode(learned) else { return }
        try? FileManager.default.createDirectory(at: Config.dataDir, withIntermediateDirectories: true)
        try? data.write(to: Config.userCapabilitiesURL)
    }
}
