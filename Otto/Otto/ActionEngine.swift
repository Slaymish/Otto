import AppKit
import Foundation

/// Dispatches the 5 primitive tool calls that the OpenAI model can invoke.
/// Runs on its own actor executor so blocking calls (NSAppleScript, AX tree)
/// never touch the main thread.
actor ActionEngine {

    // MARK: - Public dispatch

    func dispatch(name: String, args: [String: Any]) async -> [String: Any] {
        switch name {
        case "run_applescript":
            let script = args["script"] as? String ?? ""
            return runAppleScript(script)

        case "press_key":
            let combo = args["combo"] as? String ?? ""
            let app   = args["app"] as? String
            let times = args["repeat"] as? Int ?? 1
            return pressKey(combo: combo, app: app, times: times)

        case "read_screen":
            let app = args["app"] as? String
            return readScreen(app: app)

        case "open_url":
            let url = args["url"] as? String ?? ""
            return openURL(url)

        case "obs_call":
            let reqType = args["request_type"] as? String ?? ""
            let reqData = args["request_data"] as? [String: Any] ?? [:]
            return await obsCall(requestType: reqType, requestData: reqData)

        default:
            return ["status": "error", "error": "unknown tool: \(name)"]
        }
    }

    // MARK: - run_applescript

    private func runAppleScript(_ script: String) -> [String: Any] {
        guard let appleScript = NSAppleScript(source: script) else {
            return ["status": "error", "error": "failed to compile AppleScript"]
        }
        var errorDict: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            let msg = errorDict[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            return ["status": "error", "error": msg]
        }
        let output = descriptor.stringValue ?? ""
        return ["status": "ok", "output": output]
    }

    // MARK: - press_key

    private func pressKey(combo: String, app: String?, times: Int) -> [String: Any] {
        if let app {
            let activate = "tell application \"\(app)\" to activate"
            _ = runAppleScript(activate)
        }

        let parts = combo.lowercased().components(separatedBy: "+")
        let key   = parts.last ?? ""
        let mods  = Set(parts.dropLast())

        guard let (keyCode, _) = keycodeMap[key] else {
            return ["status": "error", "error": "unknown key: \(key)"]
        }

        var cgMods: CGEventFlags = []
        if mods.contains("cmd")   { cgMods.insert(.maskCommand) }
        if mods.contains("shift") { cgMods.insert(.maskShift) }
        if mods.contains("opt") || mods.contains("alt") { cgMods.insert(.maskAlternate) }
        if mods.contains("ctrl")  { cgMods.insert(.maskControl) }

        for _ in 0..<max(1, times) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                return ["status": "error", "error": "CGEvent creation failed"]
            }
            down.flags = cgMods
            up.flags   = cgMods
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return ["status": "ok"]
    }

    // MARK: - read_screen

    private func readScreen(app: String?) -> [String: Any] {
        let targetApp: String
        if let app {
            targetApp = app
        } else {
            let script = "tell application \"System Events\" to get name of first application process whose frontmost is true"
            let result = runAppleScript(script)
            targetApp = result["output"] as? String ?? ""
        }
        guard !targetApp.isEmpty else {
            return ["status": "error", "error": "could not determine target app"]
        }

        let appRef = AXUIElementCreateApplication(
            pid(for: targetApp)
        )
        var text = ""
        collectText(from: appRef, into: &text, depth: 0)
        return ["status": "ok", "app": targetApp, "text": text]
    }

    private func pid(for appName: String) -> pid_t {
        let ws = NSWorkspace.shared
        for app in ws.runningApplications where
            app.localizedName?.lowercased() == appName.lowercased() ||
            app.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true {
            return app.processIdentifier
        }
        return 0
    }

    private func collectText(from element: AXUIElement, into text: inout String, depth: Int) {
        guard depth < 8 else { return }

        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let str = value as? String, !str.isEmpty {
            text += str + "\n"
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return }
        for child in childList {
            collectText(from: child, into: &text, depth: depth + 1)
        }
    }

    // MARK: - open_url

    private func openURL(_ urlString: String) -> [String: Any] {
        guard let url = URL(string: urlString) else {
            return ["status": "error", "error": "invalid URL: \(urlString)"]
        }
        NSWorkspace.shared.open(url)
        return ["status": "ok"]
    }

    // MARK: - obs_call

    private func obsCall(requestType: String, requestData: [String: Any]) async -> [String: Any] {
        // OBS WebSocket v5 — connects to ws://localhost:4455
        guard let url = URL(string: "ws://localhost:4455") else {
            return ["status": "error", "error": "invalid OBS WebSocket URL"]
        }
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // Wait for Hello message
        guard let hello = try? await ws.receive(),
              case .string(let helloStr) = hello,
              let helloData = helloStr.data(using: .utf8),
              let helloObj = try? JSONSerialization.jsonObject(with: helloData) as? [String: Any],
              (helloObj["op"] as? Int) == 0 else {
            return ["status": "error", "error": "OBS WebSocket hello failed"]
        }

        // Send Identify
        let identify: [String: Any] = ["op": 1, "d": ["rpcVersion": 1]]
        guard let identData = try? JSONSerialization.data(withJSONObject: identify),
              let identStr = String(data: identData, encoding: .utf8) else {
            return ["status": "error", "error": "OBS identify encode failed"]
        }
        try? await ws.send(.string(identStr))

        // Wait for Identified (op 2)
        guard let identified = try? await ws.receive(),
              case .string(let idStr) = identified,
              let idData = idStr.data(using: .utf8),
              let idObj = try? JSONSerialization.jsonObject(with: idData) as? [String: Any],
              (idObj["op"] as? Int) == 2 else {
            return ["status": "error", "error": "OBS identify failed"]
        }

        // Send Request (op 6)
        var reqD: [String: Any] = ["requestType": requestType, "requestId": UUID().uuidString]
        if !requestData.isEmpty { reqD["requestData"] = requestData }
        let request: [String: Any] = ["op": 6, "d": reqD]
        guard let reqBytes = try? JSONSerialization.data(withJSONObject: request),
              let reqStr = String(data: reqBytes, encoding: .utf8) else {
            return ["status": "error", "error": "OBS request encode failed"]
        }
        try? await ws.send(.string(reqStr))

        // Wait for RequestResponse (op 7)
        guard let response = try? await ws.receive(),
              case .string(let respStr) = response,
              let respData = respStr.data(using: .utf8),
              let respObj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              (respObj["op"] as? Int) == 7,
              let d = respObj["d"] as? [String: Any] else {
            return ["status": "error", "error": "OBS response failed"]
        }

        let status = d["requestStatus"] as? [String: Any]
        let ok = status?["result"] as? Bool ?? false
        return ok
            ? ["status": "ok", "responseData": d["responseData"] ?? [:]]
            : ["status": "error", "error": status?["comment"] as? String ?? "OBS error"]
    }

    // MARK: - Key code table

    private let keycodeMap: [String: (CGKeyCode, String)] = [
        "a": (0, "a"), "s": (1, "s"), "d": (2, "d"), "f": (3, "f"),
        "h": (4, "h"), "g": (5, "g"), "z": (6, "z"), "x": (7, "x"),
        "c": (8, "c"), "v": (9, "v"), "b": (11, "b"), "q": (12, "q"),
        "w": (13, "w"), "e": (14, "e"), "r": (15, "r"), "y": (16, "y"),
        "t": (17, "t"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"),
        "4": (21, "4"), "6": (22, "6"), "5": (23, "5"), "=": (24, "="),
        "9": (25, "9"), "7": (26, "7"), "-": (27, "-"), "8": (28, "8"),
        "0": (29, "0"), "]": (30, "]"), "o": (31, "o"), "u": (32, "u"),
        "[": (33, "["), "i": (34, "i"), "p": (35, "p"), "l": (37, "l"),
        "j": (38, "j"), "'": (39, "'"), "k": (40, "k"), ";": (41, ";"),
        "\\": (42, "\\"), ",": (43, ","), "/": (44, "/"), "n": (45, "n"),
        "m": (46, "m"), ".": (47, "."), "`": (50, "`"),
        "return": (36, "return"), "tab": (48, "tab"), "space": (49, "space"),
        "delete": (51, "delete"), "escape": (53, "escape"),
        "left": (123, "left"), "right": (124, "right"),
        "down": (125, "down"), "up": (126, "up"),
        "f1": (122, "f1"), "f2": (120, "f2"), "f3": (99, "f3"),
        "f4": (118, "f4"), "f5": (96, "f5"), "f6": (97, "f6"),
        "f7": (98, "f7"), "f8": (100, "f8"), "f9": (101, "f9"),
        "f10": (109, "f10"), "f11": (103, "f11"), "f12": (111, "f12"),
    ]
}
