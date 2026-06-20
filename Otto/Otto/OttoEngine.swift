import Foundation
import Observation

/// Native Swift engine that replaces the Python IPC backend when launched with
/// --swift-engine. Publishes exactly the same observable state as PythonBridge
/// so that all SwiftUI views work without modification.
@MainActor
@Observable
final class OttoEngine: @preconcurrency OttoBridge {

    // MARK: - Published state (mirrors PythonBridge exactly)
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

    // MARK: - Private state
    private var isListening = false
    private var isSpeaking = false
    private var responseInFlight = false
    private var currentWS: URLSessionWebSocketTask?
    private var realtimeTask: Task<Void, Never>?

    private let audio = AudioEngine()
    private let actions = ActionEngine()
    private let urlSession = URLSession(configuration: .default)
    private let apiKey: String
    private let model: String

    private var wsURL: URL {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!
    }

    // MARK: - Init / deinit

    init() {
        let env = ProcessInfo.processInfo.environment
        self.apiKey = env["OPENAI_API_KEY"] ?? ""
        self.model  = env["OTTO_MODEL"] ?? "gpt-realtime-2"
    }

    func start() {
        realtimeTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    // MARK: - Reconnect loop

    private func runLoop() async {
        while !Task.isCancelled {
            await connectAndRun()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func connectAndRun() async {
        guard !apiKey.isEmpty else {
            lastError = "OPENAI_API_KEY not set"
            return
        }

        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let ws = urlSession.webSocketTask(with: req)
        currentWS = ws
        ws.resume()

        do {
            try await sendJSON(ws, sessionConfig())
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            currentWS = nil
            lastError = "Session config failed: \(error.localizedDescription)"
            return
        }

        do {
            try audio.start { [weak self] data, level in
                // Bridge from AVAudioEngine audio thread → main actor
                Task { @MainActor [weak self] in
                    await self?.onAudioFrame(data: data, level: level)
                }
            }
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            currentWS = nil
            lastError = "Mic error: \(error.localizedDescription)"
            return
        }

        isReady = true

        do {
            while !Task.isCancelled {
                let msg = try await ws.receive()
                await handleMessage(msg, ws: ws)
            }
        } catch {
            // WebSocket closed (60-min session cap or network drop) — reconnect
        }

        audio.stop()
        isReady = false
        isListening = false
        isSpeaking = false
        responseInFlight = false
        currentWS = nil
    }

    // MARK: - Audio frame handler

    private func onAudioFrame(data: Data, level: Float) async {
        guard isListening, !isSpeaking else {
            micLevel = 0
            waveformActive = false
            return
        }
        micLevel = level
        waveformActive = true
        guard let ws = currentWS else { return }
        let b64 = data.base64EncodedString()
        try? await sendJSON(ws, ["type": "input_audio_buffer.append", "audio": b64])
    }

    // MARK: - Message dispatch

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message, ws: URLSessionWebSocketTask) async {
        let obj: [String: Any]
        switch msg {
        case .string(let s):
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            obj = o
        case .data(let d):
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            obj = o
        @unknown default:
            return
        }

        guard let type = obj["type"] as? String else { return }

        switch type {

        case "response.created":
            isSpeaking = true
            isListening = false

        case "response.output_audio.delta":
            isSpeaking = true
            if let b64 = obj["delta"] as? String, let audioData = Data(base64Encoded: b64) {
                audio.enqueueAudio(audioData)
            }

        case "response.output_audio_transcript.delta":
            break  // incremental transcript — ignored in Phase 01

        case "response.output_audio_transcript.done":
            let text = (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            spokenText = text
            transcript = ""

        case "response.done":
            isSpeaking = false
            responseInFlight = false

        case "response.output_audio.done":
            isSpeaking = false

        case "conversation.item.input_audio_transcription.completed":
            let heard = (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            transcript = heard
            if !heard.isEmpty {
                await handleTranscription(ws: ws, heard: heard)
            }

        case "input_audio_buffer.speech_started":
            audio.stopPlayback()

        case "response.function_call_arguments.done":
            await handleToolCall(ws: ws, event: obj)

        case "error":
            responseInFlight = false
            let err = obj["error"] as? [String: Any]
            let code = err?["code"] as? String ?? ""
            // conversation_already_has_active_response is safe to ignore
            if code != "conversation_already_has_active_response" {
                lastError = err?["message"] as? String ?? "Realtime API error"
            }

        default:
            break
        }
    }

    // MARK: - Turn handling

    private func handleTranscription(ws: URLSessionWebSocketTask, heard: String) async {
        // Phase 01: capability context injection is stubbed; added in Phase 03.
        await createResponse(ws)
    }

    private func createResponse(_ ws: URLSessionWebSocketTask) async {
        guard !responseInFlight else { return }
        responseInFlight = true
        try? await sendJSON(ws, ["type": "response.create"])
    }

    private func handleToolCall(ws: URLSessionWebSocketTask, event: [String: Any]) async {
        guard let name   = event["name"] as? String,
              let callId = event["call_id"] as? String else { return }

        let argsString = event["arguments"] as? String ?? "{}"
        let args = (try? JSONSerialization.jsonObject(
            with: Data(argsString.utf8)) as? [String: Any]) ?? [:]

        let result = await actions.dispatch(name: name, args: args)
        responseInFlight = false

        let outputStr = (try? String(
            data: JSONSerialization.data(withJSONObject: result), encoding: .utf8)) ?? "{}"

        try? await sendJSON(ws, [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputStr,
            ],
        ])
        await createResponse(ws)
    }

    // MARK: - Session config

    private func sessionConfig() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": """
                    You are Otto, a macOS voice assistant. Use the available tools to control \
                    the user's Mac. Always confirm actions briefly after executing them.
                    """,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": [
                            "model": "gpt-4o-transcribe",
                            "language": "en",
                        ],
                        // No auto VAD — we commit the buffer manually on voice_stop
                        "turn_detection": NSNull(),
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "ballad",
                    ],
                ],
                "tools": toolDefinitions,
                "tool_choice": "auto",
            ],
        ]
    }

    // MARK: - Tool definitions (matches voice_agent.py TOOLS list)

    private var toolDefinitions: [[String: Any]] {[
        tool("run_applescript", "Execute an AppleScript snippet to automate macOS apps.",
             required: ["script"],
             props: ["script": ["type": "string", "description": "The AppleScript code to run"]]),

        tool("press_key", "Send a keyboard shortcut to the frontmost app.",
             required: ["combo"],
             props: [
                "combo":  ["type": "string",  "description": "Key combo, e.g. 'cmd+s' or 'space'"],
                "app":    ["type": "string",  "description": "Target app name (optional)"],
                "repeat": ["type": "integer", "description": "Times to repeat (default 1)"],
             ]),

        tool("read_screen", "Read visible text from the screen via Accessibility APIs.",
             required: [],
             props: ["app": ["type": "string", "description": "App to read (optional)"]]),

        tool("open_url", "Open a URL in the configured browser.",
             required: ["url"],
             props: ["url": ["type": "string", "description": "The URL to open"]]),

        tool("obs_call", "Control OBS via its WebSocket API.",
             required: ["request_type"],
             props: [
                "request_type": ["type": "string", "description": "OBS request type e.g. StartRecord"],
                "request_data": ["type": "object", "description": "Optional request payload"],
             ]),
    ]}

    private func tool(
        _ name: String, _ desc: String,
        required: [String], props: [String: Any]
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": desc,
            "parameters": [
                "type": "object",
                "properties": props,
                "required": required,
            ],
        ]
    }

    // MARK: - WebSocket helper

    private func sendJSON(_ ws: URLSessionWebSocketTask, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let str  = String(data: data, encoding: .utf8)!
        try await ws.send(.string(str))
    }

    // MARK: - OttoBridge commands

    func sendVoiceStart() {
        guard let ws = currentWS else { return }
        if isSpeaking {
            ws.cancel(with: .normalClosure, reason: Data("interrupt".utf8))
            audio.stopPlayback()
            isSpeaking = false
        }
        isListening = true
        Task { try? await sendJSON(ws, ["type": "input_audio_buffer.clear"]) }
    }

    func sendVoiceStop() {
        guard isListening, let ws = currentWS else { return }
        isListening = false
        waveformActive = false
        micLevel = 0
        // Small delay lets any in-flight audio-frame tasks finish their sends
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? await sendJSON(ws, ["type": "input_audio_buffer.commit"])
            // response.create fires from handleTranscription after the transcript arrives
        }
    }

    func sendText(_ text: String) {
        guard !responseInFlight, !isSpeaking, let ws = currentWS else { return }
        Task {
            try? await sendJSON(ws, [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]],
                ],
            ])
            await createResponse(ws)
        }
    }

    // Journal / suggestions — powered by Python sidecar in Phase 01; stubbed here
    func requestJournal()    { /* Phase 04 */ }
    func requestSuggestions(){ /* Phase 04 */ }
    func undoLearning(_ id: String)         { /* Phase 04 */ }
    func deleteCapability(_ id: String)     { /* Phase 04 */ }
    func editCapability(_ id: String, description: String?, examples: [String]?) { /* Phase 04 */ }
}
