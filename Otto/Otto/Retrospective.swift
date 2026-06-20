import Foundation

enum Retrospective {

    struct Turn {
        let phrase: String
        let tool: String
    }

    // Finds the oldest unprocessed .jsonl session log and runs it through gpt-4o-mini
    // to extract reusable capability patterns. Marks processed logs with .done suffix.
    // Designed to run at startup so termination doesn't race the API call.
    static func processLastSession() async {
        let apiKey = await MainActor.run { Config.openAIKey }
        guard !apiKey.isEmpty else { return }

        guard let logURL = oldestUnprocessed() else { return }

        let turns = parseTurns(at: logURL)
        guard !turns.isEmpty else {
            markDone(logURL)
            return
        }

        let existing = await MainActor.run { CapabilityIndex.shared.all }
        guard let result = try? await callLLM(apiKey: apiKey, turns: turns, existing: existing) else {
            return
        }

        await MainActor.run {
            for cap in result { CapabilityIndex.shared.append(cap) }
        }

        markDone(logURL)
    }

    // MARK: - File helpers

    private static func oldestUnprocessed() -> URL? {
        let dir = Config.sessionsDir
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { ($0.path < $1.path) }
            .first
    }

    private static func markDone(_ url: URL) {
        let dest = url.appendingPathExtension("done")
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    // MARK: - JSONL parsing

    private static func parseTurns(at url: URL) -> [Turn] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lastHeard = ""
        var turns: [Turn] = []

        for line in text.components(separatedBy: "\n") {
            guard let data = line.data(using: .utf8), !data.isEmpty,
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "heard":
                lastHeard = (obj["text"] as? String) ?? ""
            case "tool_call":
                guard !lastHeard.isEmpty,
                      let tool = obj["tool"] as? String,
                      (obj["ok"] as? Bool) == true else { continue }
                turns.append(Turn(phrase: lastHeard, tool: tool))
                lastHeard = ""
            default:
                break
            }
        }
        return turns
    }

    // MARK: - LLM call

    private static func callLLM(apiKey: String, turns: [Turn], existing: [Capability]) async throws -> [Capability] {
        let existingSummary = existing.prefix(20).map { "\($0.id): \($0.description)" }.joined(separator: "\n")

        let turnLines = turns.map { "  phrase: \"\($0.phrase)\"  →  tool: \($0.tool)" }.joined(separator: "\n")

        let userPrompt = """
            Session turns (phrase → successful tool call):
            \(turnLines)

            Existing capabilities (first 20):
            \(existingSummary)

            For each turn that represents a repeatable pattern, decide:
            A) If it closely matches an existing capability, add the phrase as a new example.
            B) If it's genuinely new, create a new capability.

            Respond ONLY with valid JSON (no markdown fences):
            {
              "updates": [{"id": "existing-id", "new_example": "phrase to add"}],
              "new": [{
                "id": "short-kebab-id",
                "description": "one-line description",
                "examples": ["phrase1", "phrase2"],
                "primitive": "run_applescript|press_key|read_screen|open_url|obs_call",
                "template": "template string"
              }]
            }
            """

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a macOS voice assistant capability extractor. Output only valid JSON."],
                ["role": "user",   "content": userPrompt],
            ],
            "temperature": 0.3,
            "max_tokens": 1024,
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)

        guard let resp   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = resp["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              let jsonData = content.data(using: .utf8),
              let result  = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return [] }

        var learned: [Capability] = []
        let iso = ISO8601DateFormatter()
        let now = iso.string(from: Date())

        // Apply example updates to existing capabilities
        if let updates = result["updates"] as? [[String: Any]] {
            await MainActor.run {
                for u in updates {
                    guard let id  = u["id"] as? String,
                          let ex  = u["new_example"] as? String else { continue }
                    let idx = CapabilityIndex.shared.all.firstIndex { $0.id == id }
                    if let idx {
                        var exs = CapabilityIndex.shared.all[idx].examples
                        if !exs.contains(ex) {
                            exs.append(ex)
                            CapabilityIndex.shared.edit(id, description: nil, examples: exs)
                        }
                    }
                }
            }
        }

        // Build new capability structs
        if let newCaps = result["new"] as? [[String: Any]] {
            for n in newCaps {
                guard let id   = n["id"] as? String,
                      let desc = n["description"] as? String,
                      let exs  = n["examples"] as? [String],
                      let prim = n["primitive"] as? String,
                      let tpl  = n["template"] as? String else { continue }
                learned.append(Capability(
                    id: id,
                    description: desc,
                    examples: exs,
                    primitive: prim,
                    template: tpl,
                    origin: "learned",
                    learnedAt: now,
                    timesUsed: 0,
                    lastUsed: nil,
                    confidence: 0.8,
                    requiredApps: nil
                ))
            }
        }

        return learned
    }
}

// Memberwise init for Capability (needed by Retrospective to build new instances)
extension Capability {
    init(id: String, description: String, examples: [String], primitive: String,
         template: String, origin: String, learnedAt: String?, timesUsed: Int,
         lastUsed: String?, confidence: Double, requiredApps: [String]?) {
        self.id = id
        self.description = description
        self.examples = examples
        self.primitive = primitive
        self.template = template
        self.origin = origin
        self.learnedAt = learnedAt
        self.timesUsed = timesUsed
        self.lastUsed = lastUsed
        self.confidence = confidence
        self.requiredApps = requiredApps
    }
}
