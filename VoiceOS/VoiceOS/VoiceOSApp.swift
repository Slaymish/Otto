import SwiftUI
import AppKit

@main
struct VoiceOSApp: App {
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
            NSLog("[VoiceOS] Could not locate project root — set VOICEOS_PROJECT_ROOT env var.")
            return
        }

        let venv = root.appendingPathComponent(".venv/bin/python3")
        let fallback = root.appendingPathComponent(".venv/bin/python")
        let python: URL
        if FileManager.default.fileExists(atPath: venv.path) {
            python = venv
        } else if FileManager.default.fileExists(atPath: fallback.path) {
            python = fallback
        } else {
            NSLog("[VoiceOS] No .venv python found at %@", root.path)
            return
        }

        let script = root.appendingPathComponent("src/voice_agent.py")
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--ipc"]
        process.currentDirectoryURL = root

        // Inherit environment so OPENAI_API_KEY etc. are available
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
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
            NSLog("[VoiceOS] Python exited with code %d", p.terminationStatus)
        }

        try? process.run()
        pythonProcess = process
        stdoutPipe = pipe
    }

    // MARK: - Project root discovery

    private func findProjectRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VOICEOS_PROJECT_ROOT"] {
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
}
