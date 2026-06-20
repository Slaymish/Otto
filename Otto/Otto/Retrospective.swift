import Foundation

enum Retrospective {

    struct Turn {
        let phrase: String
        let tool: String
        let args: [String: Any]
        // false when no capability was retrieved for the phrase — i.e. the model
        // improvised a working action. These are the highest-value new capabilities.
        let matched: Bool
    }

    // Finds the oldest unprocessed .jsonl session log and runs it through gpt-4o-mini
    // to extract reusable capability patterns. Marks processed logs with .done suffix.
    // Designed to run at startup so termination doesn't race the API call.
    static func processLastSession() async {
        let cfg = await MainActor.run { LLMConfig.current }
        // Need either an OpenAI key or an enabled local Ollama model.
        guard !cfg.apiKey.isEmpty || cfg.ollamaEnabled else { return }

        guard let logURL = oldestUnprocessed() else { return }

        let turns = parseTurns(at: logURL)
        guard !turns.isEmpty else {
            markDone(logURL)
            return
        }

        let existing = await MainActor.run { CapabilityIndex.shared.all }
        guard let result = try? await callLLM(cfg: cfg, turns: turns, existing: existing) else {
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
        var lastMatched = false
        var turns: [Turn] = []

        for line in text.components(separatedBy: "\n") {
            guard let data = line.data(using: .utf8), !data.isEmpty,
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "heard":
                lastHeard = (obj["text"] as? String) ?? ""
                lastMatched = !((obj["matched"] as? [Any])?.isEmpty ?? true)
            case "tool_call":
                guard !lastHeard.isEmpty,
                      let tool = obj["tool"] as? String,
                      (obj["ok"] as? Bool) == true else { continue }
                let args = (obj["args"] as? [String: Any]) ?? [:]
                turns.append(Turn(phrase: lastHeard, tool: tool, args: args, matched: lastMatched))
                lastHeard = ""
            default:
                break
            }
        }
        return turns
    }

    // MARK: - LLM call

    // Snapshot of the LLM settings, read once on the main actor.
    struct LLMConfig {
        let apiKey: String
        let ollamaEnabled: Bool
        let ollamaHost: String
        let ollamaModel: String

        @MainActor static var current: LLMConfig {
            LLMConfig(
                apiKey: Config.openAIKey,
                ollamaEnabled: Config.ollamaEnabled,
                ollamaHost: Config.ollamaHost,
                ollamaModel: Config.ollamaModel
            )
        }
    }

    private static func callLLM(cfg: LLMConfig, turns: [Turn], existing: [Capability]) async throws -> [Capability] {
        let existingSummary = existing.prefix(20).map { "\($0.id): \($0.description)" }.joined(separator: "\n")

        let turnLines = turns.map { t -> String in
            let argsJSON = (try? String(
                data: JSONSerialization.data(withJSONObject: t.args), encoding: .utf8)) ?? "{}"
            let tag = t.matched ? "[matched existing capability]" : "[IMPROVISED — no capability matched]"
            return "  \(tag) phrase: \"\(t.phrase)\"  →  tool: \(t.tool)  args: \(argsJSON)"
        }.joined(separator: "\n")

        let userPrompt = """
            Session turns (phrase → successful tool call, with the exact arguments used):
            \(turnLines)

            Existing capabilities (first 20):
            \(existingSummary)

            Turns tagged [IMPROVISED] had NO matching capability — the model figured the
            action out on its own. These are the most valuable to capture as NEW
            capabilities so they're retrieved instantly next time.

            For each turn that represents a repeatable pattern, decide:
            A) If it closely matches an existing capability, add the phrase as a new example.
            B) If it's genuinely new (especially IMPROVISED turns), create a new capability.
               Build the "template" from the actual `args` shown above, replacing the
               variable parts of the phrase with {placeholders} (e.g. {query}, {app}).

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

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a macOS voice assistant capability extractor. Output only valid JSON."],
            ["role": "user",   "content": userPrompt],
        ]

        // Prefer a local Ollama model when enabled; fall back to OpenAI on any failure.
        var content: String?
        if cfg.ollamaEnabled {
            content = try? await chat(
                url: URL(string: cfg.ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions")!,
                model: cfg.ollamaModel, apiKey: nil, messages: messages)
        }
        if content == nil, !cfg.apiKey.isEmpty {
            content = try await chat(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                model: "gpt-4o-mini", apiKey: cfg.apiKey, messages: messages)
        }

        guard let content,
              let jsonData = stripFences(content).data(using: .utf8),
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

    // MARK: - HTTP helpers

    // Single OpenAI-compatible /v1/chat/completions request. Works for both OpenAI
    // and Ollama (Ollama omits the apiKey). Returns the assistant message content.
    private static func chat(url: URL, model: String, apiKey: String?, messages: [[String: Any]]) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "stream": false,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let resp    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = resp["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else { throw URLError(.badServerResponse) }
        return content
    }

    // Local models sometimes wrap JSON in ```json fences despite instructions.
    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        }
        if let fence = t.range(of: "```", options: .backwards) {
            t = String(t[..<fence.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
