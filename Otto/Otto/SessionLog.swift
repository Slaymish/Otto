import Foundation

final class SessionLog {
    static let shared = SessionLog()

    private var fileURL: URL?
    private let queue = DispatchQueue(label: "otto.sessionlog", qos: .utility)
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func startSession() {
        let dir = Config.sessionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = iso8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(ts).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileURL = url
    }

    func currentURL() -> URL? { fileURL }

    func logHeard(_ text: String) {
        append(["type": "heard", "text": text])
    }

    func logSpoken(_ text: String) {
        append(["type": "spoken", "text": text])
    }

    func logToolCall(_ tool: String, ok: Bool, latencyMs: Int) {
        append(["type": "tool_call", "tool": tool, "ok": ok, "latency_ms": latencyMs])
    }

    func logError(_ message: String) {
        append(["type": "error", "message": message])
    }

    private func append(_ event: [String: Any]) {
        var e = event
        e["ts"] = iso8601.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: e),
              let line = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            guard let url = self?.fileURL else { return }
            guard let fh = try? FileHandle(forWritingTo: url) else { return }
            fh.seekToEndOfFile()
            fh.write((line + "\n").data(using: .utf8)!)
            try? fh.close()
        }
    }
}
