import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var store = SettingsStore.shared
    @State private var page = 0
    @State private var showKey = false

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
            Text("All optional — you can change these any time in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                labeledField("Your name",    placeholder: "e.g. Hamish",        binding: $store.userName)
                labeledField("Microphone",   placeholder: "Partial name, e.g. Scarlett", binding: $store.micName)
                labeledField("Browser",      placeholder: "e.g. Chrome  (default: Safari)", binding: $store.browserName)

                Toggle("Use a local Ollama model for learning", isOn: $store.ollamaEnabled)
                    .toggleStyle(.switch)
                    .padding(.top, 6)
                if store.ollamaEnabled {
                    labeledField("Ollama model", placeholder: "e.g. llama3.1", binding: $store.ollamaModel)
                    Text("Runs the post-session retrospective locally instead of OpenAI. Falls back to OpenAI if Ollama isn't reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Button("Set Up Otto →") {
                store.save()
                page = 3
            }
            .buttonStyle(.borderedProminent)

        default:
            Button("Launch Otto") {
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
