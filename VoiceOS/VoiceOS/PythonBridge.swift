import Foundation
import Network
import Observation

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

    // MARK: - Private
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "voiceos.ipc", qos: .userInteractive)

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
            default:
                break
            }
        }
    }
}
