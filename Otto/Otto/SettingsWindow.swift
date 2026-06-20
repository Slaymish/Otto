import SwiftUI
import AppKit

// MARK: - Window controller

/// Manages the "Otto — Settings" window: edits the values held in SettingsStore
/// (API key, name, mic, browser). Saving persists them and restarts the Python
/// backend so the new values take effect, since they're read once at launch.
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let updateChecker: UpdateChecker
    private let onSaved: () -> Void

    init(updateChecker: UpdateChecker, onSaved: @escaping () -> Void) {
        self.updateChecker = updateChecker
        self.onSaved = onSaved
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        SettingsStore.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let view = SettingsView(
            updateChecker: updateChecker,
            onSave: { [weak self] in
                self?.onSaved()
                self?.window?.orderOut(nil)
            },
            onClose: { [weak self] in self?.window?.orderOut(nil) }
        )
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Otto \u{2014} Settings"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: view)
        window = w
    }
}

// MARK: - Settings view

struct SettingsView: View {
    var updateChecker: UpdateChecker
    var onSave: () -> Void
    var onClose: () -> Void

    @ObservedObject private var store = SettingsStore.shared
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    apiKeySection
                    preferencesSection
                    shortcutsSection
                    updatesSection
                }
                .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 420)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAI API Key")
                .font(.headline)
            Text("Stored in the system Keychain \u{2014} it never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-\u{2026}", text: $store.openAIKey)
                    } else {
                        SecureField("sk-\u{2026}", text: $store.openAIKey)
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
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.headline)
            Text("All optional.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                labeledField("Your name", placeholder: "e.g. Hamish", binding: $store.userName)
                labeledField("Microphone", placeholder: "Partial name, e.g. Scarlett", binding: $store.micName)
                labeledField("Browser", placeholder: "e.g. Chrome  (default: Safari)", binding: $store.browserName)
                Toggle("Start listening when Otto opens", isOn: $store.micAutoStart)
                    .toggleStyle(.switch)
                    .padding(.top, 6)
            }
            .padding(.top, 4)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(.headline)
            HotkeyRecorderView(label: "Summon Otto", config: $store.summonHotkey)
            HotkeyRecorderView(label: "Open Journal", config: $store.journalHotkey)
            if store.summonHotkey == store.journalHotkey {
                Text("Both shortcuts are the same \u{2014} only one will fire.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.headline)
            HStack {
                Text("Current version \(updateChecker.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check now") {
                    Task { await updateChecker.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let update = updateChecker.availableUpdate {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Version \(update.version) is available")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Update") {
                        Task { await updateChecker.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
            }
            if case .downloading = updateChecker.status {
                ProgressView().controlSize(.small)
            } else if case .failed(let msg) = updateChecker.status {
                Text(msg).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Saving restarts Otto's backend.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                store.save()
                onSave()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(store.openAIKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

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
