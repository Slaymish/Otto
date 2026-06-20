import Carbon
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
    private var journalController: JournalController?
    private var settingsController: SettingsController?
    private var menuBarController: MenuBarController?
    private var hotkeyManager: HotkeyManager?
    private var pythonProcess: Process?
    private var stdoutPipe: Pipe?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Otto] app started")

        // Show first-run onboarding only when running from the installed bundle.
        if resourcesHaveBackend && !SettingsStore.shared.isConfigured {
            NSApp.setActivationPolicy(.regular)
            showOnboarding()
        } else {
            NSApp.setActivationPolicy(.accessory)
            startMainApp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pythonProcess?.terminate()
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let view = OnboardingView {
            DispatchQueue.main.async {
                self.onboardingWindow?.orderOut(nil)
                self.onboardingWindow = nil
                NSApp.setActivationPolicy(.accessory)
                self.startMainApp()
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Otto"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main app startup

    private func startMainApp() {
        paletteController = PaletteController(bridge: bridge)
        journalController = JournalController(bridge: bridge)
        settingsController = SettingsController(onSaved: { [weak self] in self?.restartPython() })

        paletteController?.onOpenJournal = { [weak self] in self?.journalController?.show() }

        let menuBar = MenuBarController()
        menuBar.onOpenSearch = { [weak self] in self?.paletteController?.show() }
        menuBar.onOpenJournal = { [weak self] in self?.journalController?.show() }
        menuBar.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        menuBarController = menuBar

        hotkeyManager = HotkeyManager(onToggle: { [weak self] in
            self?.paletteController?.toggle()
        })
        hotkeyManager?.register()

        launchPython()
    }

    // MARK: - Restart backend (e.g. after settings change)

    /// Tears down the running Python subprocess and relaunches it so freshly saved
    /// settings (read once at launch via env) take effect.
    private func restartPython() {
        bridge.disconnect()
        if let proc = pythonProcess {
            proc.terminationHandler = nil
            proc.terminate()
        }
        pythonProcess = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        launchPython()
    }

    // MARK: - Python subprocess

    /// True when src/voice_agent.py is bundled inside Contents/Resources (installed app).
    private var resourcesHaveBackend: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("src/voice_agent.py").path)
    }

    private var appSupportDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Otto")
    }

    private func launchPython() {
        let isBundled = resourcesHaveBackend

        // Resolve the directory that contains src/ and memory/.
        let scriptRoot: URL
        let pythonURL: URL

        if isBundled {
            guard let resources = Bundle.main.resourceURL else {
                print("[Otto] ERROR: no bundle resources URL")
                return
            }
            scriptRoot = resources
            let venv = appSupportDir.appendingPathComponent(".venv")
            let py3  = venv.appendingPathComponent("bin/python3")
            let py   = venv.appendingPathComponent("bin/python")
            if FileManager.default.fileExists(atPath: py3.path) {
                pythonURL = py3
            } else if FileManager.default.fileExists(atPath: py.path) {
                pythonURL = py
            } else {
                print("[Otto] ERROR: no venv python in \(venv.path) — run onboarding first")
                return
            }
        } else {
            // Dev mode: walk up from bundle to find the project root.
            guard let root = findProjectRoot() else {
                print("[Otto] ERROR: could not locate project root — set OTTO_PROJECT_ROOT env var.")
                return
            }
            scriptRoot = root
            let py3 = root.appendingPathComponent(".venv/bin/python3")
            let py  = root.appendingPathComponent(".venv/bin/python")
            if FileManager.default.fileExists(atPath: py3.path) {
                pythonURL = py3
            } else if FileManager.default.fileExists(atPath: py.path) {
                pythonURL = py
            } else {
                print("[Otto] ERROR: no .venv python found at \(root.path)")
                return
            }
        }

        print("[Otto] script root: \(scriptRoot.path)")
        print("[Otto] python:      \(pythonURL.path)")

        let script = scriptRoot.appendingPathComponent("src/voice_agent.py")
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [script.path, "--ipc"]
        process.currentDirectoryURL = scriptRoot

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"

        if isBundled {
            // Tell Python where to write user data (capabilities, sessions, embeddings).
            env["OTTO_DATA_DIR"] = appSupportDir.path
            // Inject settings saved during onboarding (Keychain / UserDefaults).
            for (k, v) in SettingsStore.shared.asEnvironment() where env[k] == nil {
                env[k] = v
            }
            // Power-user override: .env in Application Support takes precedence.
            for (k, v) in loadDotEnv(root: appSupportDir) {
                env[k] = v
            }
        } else {
            // Dev mode: merge .env from project root, then settings store as fallback.
            for (k, v) in loadDotEnv(root: scriptRoot) where env[k] == nil {
                env[k] = v
            }
            for (k, v) in SettingsStore.shared.asEnvironment() where env[k] == nil {
                env[k] = v
            }
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
    private func loadDotEnv(root: URL) -> [String: String] {
        let file = root.appendingPathComponent(".env")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { continue }
            if s.hasPrefix("export ") { s = String(s.dropFirst(7)) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
               (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }
}
