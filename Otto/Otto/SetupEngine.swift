import Foundation

final class SetupEngine: ObservableObject {

    enum Phase: Equatable {
        case idle, creatingVenv, installingDeps, done
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.creatingVenv, .creatingVenv),
                 (.installingDeps, .installingDeps), (.done, .done): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var statusLine: String = ""

    func run(dataDir: URL, requirementsURL: URL) async {
        guard let python = findPython() else {
            await set { self.phase = .failed("Python 3 not found.\nInstall Xcode Command Line Tools:\n  xcode-select --install") }
            return
        }

        let venv = dataDir.appendingPathComponent(".venv")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: venv.path) {
            await set { self.phase = .creatingVenv; self.statusLine = "Creating Python environment…" }
            let (ok, out) = await subprocess(python.path, args: ["-m", "venv", venv.path])
            guard ok else {
                await set { self.phase = .failed("venv creation failed:\n\(out)") }
                return
            }
        }

        await set { self.phase = .installingDeps; self.statusLine = "Installing dependencies…" }
        let pip = venv.appendingPathComponent("bin/pip")
        let (ok, out) = await subprocess(pip.path, args: ["install", "--quiet", "-r", requirementsURL.path])
        guard ok else {
            await set { self.phase = .failed("Dependency install failed:\n\(out)\n\nCheck your internet connection and try again.") }
            return
        }

        await set { self.phase = .done }
    }

    // MARK: - Helpers

    private func findPython() -> URL? {
        ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @MainActor
    private func set(_ update: () -> Void) { update() }

    private func subprocess(_ exe: String, args: [String]) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus == 0, out + err))
            }
            try? p.run()
        }
    }
}
