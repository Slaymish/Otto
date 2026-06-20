// swiftc CapabilityIndexTests.swift -o /tmp/ci && /tmp/ci
import Foundation

// Minimal capability struct for standalone test (matches CapabilityIndex.swift layout)
struct Capability: Codable {
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

    enum CodingKeys: String, CodingKey {
        case id, description, examples, primitive, template, origin
        case learnedAt = "learned_at", timesUsed = "times_used"
        case lastUsed = "last_used", confidence
    }
}

// Minimal keyword search (matches CapabilityIndex.retrieve logic)
func tokens(_ text: String) -> Set<String> {
    Set(text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count > 2 })
}

func retrieve(query: String, from caps: [Capability], topK: Int = 3) -> [Capability] {
    let qToks = tokens(query)
    guard !qToks.isEmpty else { return [] }
    return caps
        .map { cap -> (Capability, Double) in
            let text = ([cap.description] + cap.examples).joined(separator: " ")
            let cToks = tokens(text)
            let overlap = Double(qToks.intersection(cToks).count)
            let score = overlap / Double(qToks.union(cToks).count)
            return (cap, score)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .prefix(topK)
        .map { $0.0 }
}

func makeCap(id: String, description: String, examples: [String]) -> Capability {
    Capability(id: id, description: description, examples: examples,
               primitive: "run_applescript", template: "", origin: "shipped",
               learnedAt: nil, timesUsed: 0, lastUsed: nil, confidence: 1.0)
}

func runTests() {
    let caps = [
        makeCap(id: "spotify-play",  description: "Play music in Spotify",         examples: ["play spotify", "start music"]),
        makeCap(id: "chrome-open",   description: "Open Chrome browser",            examples: ["open chrome", "launch chrome"]),
        makeCap(id: "volume-up",     description: "Increase system volume",         examples: ["turn up volume", "louder"]),
    ]

    // Test 1: exact keyword match
    let r1 = retrieve(query: "open chrome browser", from: caps)
    guard r1.first?.id == "chrome-open" else {
        print("FAIL test1: expected chrome-open, got \(r1.first?.id ?? "nil")")
        exit(1)
    }
    print("PASS test1: 'open chrome browser' retrieves chrome-open")

    // Test 2: music-related query hits Spotify
    let r2 = retrieve(query: "play some music", from: caps)
    guard r2.first?.id == "spotify-play" else {
        print("FAIL test2: expected spotify-play, got \(r2.first?.id ?? "nil")")
        exit(1)
    }
    print("PASS test2: 'play some music' retrieves spotify-play")

    // Test 3: empty query returns nothing
    let r3 = retrieve(query: "", from: caps)
    guard r3.isEmpty else {
        print("FAIL test3: empty query should return empty, got \(r3.count)")
        exit(1)
    }
    print("PASS test3: empty query returns no results")

    // Test 4: unrelated query returns nothing
    let r4 = retrieve(query: "xyz qrs nomatch", from: caps)
    guard r4.isEmpty else {
        print("FAIL test4: unrelated query should return empty, got \(r4.count)")
        exit(1)
    }
    print("PASS test4: unrelated query returns no results")

    // Test 5: JSON round-trip for Codable
    let cap = makeCap(id: "test-cap", description: "Test capability", examples: ["do thing"])
    guard let data = try? JSONEncoder().encode(cap),
          let decoded = try? JSONDecoder().decode(Capability.self, from: data),
          decoded.id == "test-cap",
          decoded.examples.first == "do thing" else {
        print("FAIL test5: Codable round-trip failed")
        exit(1)
    }
    print("PASS test5: Capability Codable round-trip preserved id and examples")

    print("\nAll CapabilityIndex tests passed.")
}

runTests()
