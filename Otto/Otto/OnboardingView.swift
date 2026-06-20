import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var store = SettingsStore.shared
    @StateObject  private var setup = SetupEngine()
    @State private var page = 0
    @State private var showKey = false

    private var dataDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Otto")
    }

    private var requirementsURL: URL? {
        // Bundle mode: resources are in Contents/Resources/
        if let url = Bundle.main.url(forResource: "requirements", withExtension: "txt") { return url }
        // Dev mode fallback: walk up from bundle to project root
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("requirements.txt")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: page)
            Divider()
            navBar
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0: welcomePage
        case 1: apiKeyPage
        case 2: preferencesPage
        case 3: installingPage
        default: donePage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }
            Text("Welcome to Otto")
                .font(.largeTitle.bold())
            Text("Otto is an AI voice assistant for your Mac.\nSet it up once — then just talk.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var apiKeyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI API Key")
                .font(.title2.bold())
            Text("Otto uses OpenAI's Realtime API for voice processing. Your key is stored in the system Keychain — it never leaves this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $store.openAIKey)
                    } else {
                        SecureField("sk-…", text: $store.openAIKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showKey ? "Hide key" : "Show key")
            }

            Link("Get a key at platform.openai.com →",
                 destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var preferencesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2.bold())
            Text("All optional — you can change these any time by editing ~/Library/Application\u{00A0}Support/Otto/.env.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                labeledField("Your name",    placeholder: "e.g. Hamish",        binding: $store.userName)
                labeledField("Microphone",   placeholder: "Partial name, e.g. Scarlett", binding: $store.micName)
                labeledField("Browser",      placeholder: "e.g. Chrome  (default: Safari)", binding: $store.browserName)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installingPage: some View {
        VStack(spacing: 24) {
            switch setup.phase {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Environment ready")
                    .font(.title3.bold())

            case .failed(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Setup failed")
                    .font(.title3.bold())
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            default:
                ProgressView()
                    .scaleEffect(1.5)
                Text(setup.statusLine.isEmpty ? "Preparing…" : setup.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 340)
            }
        }
        .padding(40)
        .task {
            guard setup.phase == .idle, let req = requirementsURL else { return }
            await setup.run(dataDir: dataDir, requirementsURL: req)
        }
        .onChange(of: setup.phase) { _, newPhase in
            if newPhase == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { page = 4 }
            }
        }
    }

    private var donePage: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Otto is ready")
                .font(.largeTitle.bold())
            Text("Press ⌥Space anytime to summon the command palette.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack {
            if page > 0 && page < 3 {
                Button("← Back") { page -= 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch page {
        case 0:
            Button("Get Started →") { page = 1 }
                .buttonStyle(.borderedProminent)

        case 1:
            Button("Continue →") {
                store.save()
                page = 2
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.openAIKey.trimmingCharacters(in: .whitespaces).isEmpty)

        case 2:
            Button("Set Up Otto →") { page = 3 }
                .buttonStyle(.borderedProminent)

        case 3:
            if case .failed = setup.phase {
                Button("Retry") {
                    Task {
                        guard let req = requirementsURL else { return }
                        await setup.run(dataDir: dataDir, requirementsURL: req)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

        default:
            Button("Launch Otto") {
                store.save()
                onComplete()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func labeledField(_ label: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }
}
