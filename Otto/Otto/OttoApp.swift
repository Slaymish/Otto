import SwiftUI
import AppKit

@main
struct OttoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No visible scene — the palette is an NSPanel managed by AppDelegate.
        Settings { EmptyView() }
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate {

    private let bridge = PythonBridge()
    private var paletteController: PaletteController?
    private var hotkeyManager: HotkeyManager?
    private var pythonProcess: Process?
    private var stdoutPipe: Pipe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Otto] app started")
        NSApp.setActivationPolicy(.accessory)

        paletteController = PaletteController(bridge: bridge)

        hotkeyManager = HotkeyManager(onToggle: { [weak self] in
            self?.paletteController?.toggle()
        })
        hotkeyManager?.register()

        launchPython()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pythonProcess?.terminate()
    }

    // MARK: - Python subprocess

    private func launchPython() {
        guard let root = findProjectRoot() else {
            print("[Otto] ERROR: could not locate project root — set OTTO_PROJECT_ROOT env var.")
            return
        }
        print("[Otto] project root: \(root.path)")

        let venv = root.appendingPathComponent(".venv/bin/python3")
        let fallback = root.appendingPathComponent(".venv/bin/python")
        let python: URL
        if FileManager.default.fileExists(atPath: venv.path) {
            python = venv
        } else if FileManager.default.fileExists(atPath: fallback.path) {
            python = fallback
        } else {
            print("[Otto] ERROR: no .venv python found at \(root.path)")
            return
        }
        print("[Otto] launching python: \(python.path)")

        let script = root.appendingPathComponent("src/voice_agent.py")
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--ipc"]
        process.currentDirectoryURL = root

        // Inherit environment; merge .env so OPENAI_API_KEY is available even when
        // the app is launched via Finder or open(1) which don't inherit shell env vars.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        for (key, value) in loadDotEnv(root: root) where env[key] == nil {
            env[key] = value
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for part in line.components(separatedBy: "\n") {
                if part.hasPrefix("IPC_PORT="), let port = UInt16(part.dropFirst("IPC_PORT=".count)) {
                    DispatchQueue.main.async { self?.bridge.connect(port: port) }
                }
            }
        }

        process.terminationHandler = { p in
            print("[Otto] python exited with code \(p.terminationStatus)")
        }

        try? process.run()
        pythonProcess = process
        stdoutPipe = pipe
    }

    // MARK: - Project root discovery

    private func findProjectRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["OTTO_PROJECT_ROOT"]
            ?? ProcessInfo.processInfo.environment["VOICEOS_PROJECT_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("src/voice_agent.py").path) {
                return url
            }
        }
        return nil
    }

    /// Reads KEY=VALUE pairs from <root>/.env; ignores comments and blank lines.
    /// Quoted values have their surrounding single/double quotes stripped.
    private func loadDotEnv(root: URL) -> [String: String] {
        let file = root.appendingPathComponent(".env")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { continue }
            // Strip optional leading `export `
            if s.hasPrefix("export ") { s = String(s.dropFirst(7)) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
               (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }
}
