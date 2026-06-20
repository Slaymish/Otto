import Foundation
import Network
import Observation

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

/// Manages the TCP connection to the Python backend and publishes state for the UI.
@Observable
final class PythonBridge {

    // MARK: - Published state (read by SwiftUI views)
    var micLevel: Float = 0
    var waveformActive = false
    var transcript = ""
    var spokenText = ""
    var isReady = false
    var lastError: String?
    var learnedEvent: LearnedEvent?
    var journalHeader: JournalHeader?
    var journalCards: [JournalCard] = []
    var recentPhrases: [RecentPhrase] = []

    // MARK: - Private
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "otto.ipc", qos: .userInteractive)

    // MARK: - Lifecycle

    func connect(port: UInt16) {
        let host = NWEndpoint.Host("127.0.0.1")
        let p = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: host, port: p, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed(let err):
                    self?.lastError = err.localizedDescription
                case .cancelled:
                    self?.isReady = false
                default:
                    break
                }
            }
        }
        connection?.start(queue: queue)
        scheduleReceive()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Commands → Python

    func sendVoiceStart() { send(["type": "voice_start"]) }
    func sendVoiceStop()  { send(["type": "voice_stop"]) }

    func sendText(_ text: String) {
        send(["type": "text_input", "text": text])
    }

    func requestJournal() { send(["type": "request_journal"]) }
    func requestSuggestions() { send(["type": "request_suggestions"]) }
    func undoLearning(_ id: String) { send(["type": "undo_learning", "id": id]) }
    func deleteCapability(_ id: String) { send(["type": "delete_capability", "id": id]) }
    func editCapability(_ id: String, description: String?, examples: [String]?) {
        var msg: [String: Any] = ["type": "edit_capability", "id": id]
        if let description { msg["description"] = description }
        if let examples { msg["examples"] = examples }
        send(msg)
    }

    // MARK: - Private helpers

    private func send(_ msg: [String: Any]) {
        guard let connection,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        connection.send(content: line.data(using: .utf8), completion: .idempotent)
    }

    private func scheduleReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            self.drainBuffer()
            if error == nil { self.scheduleReceive() }
        }
    }

    private func drainBuffer() {
        while let newline = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<newline]
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
            handleMessage(lineData)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case "ready":
                self.isReady = true
            case "waveform":
                self.micLevel = (obj["level"] as? NSNumber)?.floatValue ?? 0
                self.waveformActive = (obj["active"] as? Bool) ?? false
            case "transcript":
                self.transcript = (obj["text"] as? String) ?? ""
            case "spoken":
                self.spokenText = (obj["text"] as? String) ?? ""
                self.transcript = ""
            case "tool_call":
                break // could show a brief ✓ flash here
            case "error":
                self.lastError = (obj["message"] as? String) ?? "unknown error"
            case "learned":
                self.learnedEvent = LearnedEvent(
                    id: (obj["id"] as? String) ?? "",
                    action: (obj["action"] as? String) ?? "",
                    phrase: (obj["phrase"] as? String) ?? "",
                    description: (obj["description"] as? String) ?? "",
                    primitive: (obj["primitive"] as? String) ?? "")
            case "suggestions":
                let recent = (obj["recent"] as? [[String: Any]]) ?? []
                self.recentPhrases = recent.compactMap { item in
                    guard let phrase = item["phrase"] as? String,
                          let count = (item["count"] as? NSNumber)?.intValue else { return nil }
                    return RecentPhrase(phrase: phrase, count: count)
                }
            case "journal":
                if let header = obj["header"] as? [String: Any] {
                    self.journalHeader = JournalHeader(
                        capabilities: (header["capabilities"] as? NSNumber)?.intValue ?? 0,
                        learned: (header["learned"] as? NSNumber)?.intValue ?? 0,
                        commands: (header["commands"] as? NSNumber)?.intValue ?? 0)
                }
                let cards = (obj["cards"] as? [[String: Any]]) ?? []
                self.journalCards = cards.map { c in
                    JournalCard(
                        id: (c["id"] as? String) ?? "",
                        description: (c["description"] as? String) ?? "",
                        examples: (c["examples"] as? [String]) ?? [],
                        primitive: (c["primitive"] as? String) ?? "",
                        template: (c["template"] as? String) ?? "",
                        origin: (c["origin"] as? String) ?? "shipped",
                        learnedAt: c["learned_at"] as? String,
                        timesUsed: (c["times_used"] as? NSNumber)?.intValue ?? 0,
                        lastUsed: c["last_used"] as? String,
                        confidence: (c["confidence"] as? NSNumber)?.doubleValue ?? 0)
                }
            default:
                break
            }
        }
    }
}
