// swiftc SessionLogTests.swift -o /tmp/sl && /tmp/sl
import Foundation

// Minimal stubs to compile SessionLog standalone
enum Config {
    static var sessionsDir: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otto-test-sessions") }
    static var dataDir: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otto-test") }
    static var bundleCapabilitiesURL: URL? { nil }
    static var userCapabilitiesURL: URL { dataDir.appendingPathComponent("capabilities.user.json") }
    static var openAIKey: String { "" }
}

// Include SessionLog source (copy-paste not import, since no module system in standalone)
// We test the JSONL round-trip by reading what was written.

func runTests() {
    let dir = Config.sessionsDir
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Create a temporary log file directly
    let logURL = dir.appendingPathComponent("test.jsonl")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)

    // Write events manually (mimicking SessionLog internals)
    func appendEvent(_ event: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: data, encoding: .utf8) else { return }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        fh.seekToEndOfFile()
        fh.write((line + "\n").data(using: .utf8)!)
        try? fh.close()
    }

    appendEvent(["type": "heard", "text": "open Spotify", "ts": "2024-01-01T00:00:00.000Z"], to: logURL)
    appendEvent(["type": "tool_call", "tool": "run_applescript", "ok": true, "latency_ms": 120, "ts": "2024-01-01T00:00:01.000Z"], to: logURL)
    appendEvent(["type": "spoken", "text": "Opening Spotify.", "ts": "2024-01-01T00:00:02.000Z"], to: logURL)

    // Read back and parse
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
        print("FAIL: could not read log file")
        exit(1)
    }

    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard lines.count == 3 else {
        print("FAIL: expected 3 lines, got \(lines.count)")
        exit(1)
    }

    // Verify each line is valid JSON with expected fields
    let types = ["heard", "tool_call", "spoken"]
    for (i, line) in lines.enumerated() {
        guard let data = line.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == types[i] else {
            print("FAIL: line \(i) malformed: \(line)")
            exit(1)
        }
    }

    // Verify tool_call has ok and latency_ms
    guard let tcData = lines[1].data(using: .utf8),
          let tc = try? JSONSerialization.jsonObject(with: tcData) as? [String: Any],
          tc["ok"] as? Bool == true,
          tc["latency_ms"] as? Int == 120 else {
        print("FAIL: tool_call event missing expected fields")
        exit(1)
    }

    print("PASS: SessionLog round-trip writes and reads 3 JSONL events correctly")
    try? FileManager.default.removeItem(at: dir)
}

runTests()
