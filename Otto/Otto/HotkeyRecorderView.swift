import SwiftUI
import AppKit

/// A "click to record" control that captures the next key combo into a HotkeyConfig.
/// While recording, a local key-down monitor intercepts events; Esc cancels.
struct HotkeyRecorderView: View {
    let label: String
    @Binding var config: HotkeyConfig

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggle) {
                Text(recording ? "Press keys…" : config.displayString)
                    .font(.system(.body, design: .rounded).monospaced())
                    .frame(minWidth: 96)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(recording ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels without changing the binding.
            if event.keyCode == 53 { // kVK_Escape
                stop()
                return nil
            }
            if let cfg = HotkeyConfig(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags) {
                config = cfg
                stop()
            }
            return nil // swallow the event while recording
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }
}
