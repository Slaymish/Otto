import SwiftUI
import AppKit

private extension Notification.Name {
    static let paletteDidShow = Notification.Name("OttoPaletteDidShow")
}

/// How long a spoken result lingers before it auto-clears (seconds).
private let resultLingerSeconds: UInt64 = 8

/// The floating command palette — text field + hold-to-talk mic button + waveform + result.
/// Hosted in a borderless `CommandPanel` by `PaletteController`.
struct CommandPalette: View {
    // @Observable PythonBridge — SwiftUI tracks reads automatically, no wrapper needed.
    var bridge: PythonBridge
    var onDismiss: () -> Void = {}
    var onOpenJournal: () -> Void = {}

    @State private var inputText = ""
    @State private var isHoldingMic = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if bridge.waveformActive || isHoldingMic {
                WaveformView(level: bridge.micLevel, active: bridge.waveformActive)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let error = bridge.lastError {
                errorRow(error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !bridge.spokenText.isEmpty {
                resultRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let learned = bridge.learnedEvent {
                learnedChip(learned)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.waveformActive)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.spokenText)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.lastError)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.learnedEvent)
        .frame(width: 640)
        .background { paletteBackground }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .padding(1) // prevent shadow clipping
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onAppear { textFieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .paletteDidShow)) { _ in
            inputText = ""
            textFieldFocused = true
        }
        // Auto-clear a spoken result after it has lingered, so the palette
        // returns to a clean state instead of holding stale text.
        .task(id: bridge.spokenText) {
            guard !bridge.spokenText.isEmpty else { return }
            try? await Task.sleep(nanoseconds: resultLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            bridge.spokenText = ""
        }
        .task(id: bridge.learnedEvent) {
            guard bridge.learnedEvent != nil else { return }
            try? await Task.sleep(nanoseconds: resultLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            bridge.learnedEvent = nil
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 12) {
            statusGlyph

            TextField("Ask anything…", text: $inputText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)
                .focused($textFieldFocused)
                .onSubmit { submitText() }

            micButton
        }
    }

    // MARK: - Status glyph (connection state)

    /// Leading glyph: a magnifier when ready, a pulsing dot while connecting.
    @ViewBuilder private var statusGlyph: some View {
        if bridge.isReady {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 18)
                .transition(.opacity)
        } else {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .frame(width: 18)
                .opacity(0.9)
                .help("Connecting to the voice backend…")
                .transition(.opacity)
        }
    }

    // MARK: - Mic button (hold to talk)

    private var micButton: some View {
        Image(systemName: isHoldingMic ? "waveform" : "mic.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isHoldingMic ? Color.white : Color.secondary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isHoldingMic ? Color.accentColor : Color.secondary.opacity(0.14))
            )
            .scaleEffect(isHoldingMic ? 1.12 : 1.0)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: isHoldingMic)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHoldingMic else { return }
                        isHoldingMic = true
                        bridge.lastError = nil
                        bridge.sendVoiceStart()
                    }
                    .onEnded { _ in
                        guard isHoldingMic else { return }
                        isHoldingMic = false
                        bridge.sendVoiceStop()
                    }
            )
            .help("Hold to talk")
    }

    // MARK: - Result row

    private var resultRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            Text(bridge.spokenText)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Learned nudge chip

    private func learnedChip(_ event: LearnedEvent) -> some View {
        let verb = event.action == "new_capability" ? "Learned" : "Now also"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("\(verb) \u{201C}\(event.phrase)\u{201D}")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                bridge.undoLearning(event.id)
                bridge.learnedEvent = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button("Edit") {
                bridge.learnedEvent = nil
                onOpenJournal()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: - Error row

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.orange)
                .padding(.top, 2)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Background

    // Splitting glass/material into separate @available-attributed properties lets
    // swiftc on older SDKs compile without seeing the macOS 26-only glassEffect API.
    @ViewBuilder private var paletteBackground: some View {
        if #available(macOS 26.0, *) {
            glassBackground
        } else {
            materialBackground
        }
    }

    @available(macOS 26.0, *)
    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.clear)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var materialBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func submitText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        bridge.spokenText = ""
        bridge.lastError = nil
        bridge.sendText(text)
        inputText = ""
    }
}


// MARK: - Keyable panel

/// A borderless `NSPanel` that can still become key/main.
///
/// The default `NSPanel`/`NSWindow` returns `false` for both when the style mask
/// is `.borderless`, which leaves every hosted SwiftUI control inert: the text
/// field can't focus, buttons and gestures never receive clicks, and key events
/// (Esc) are dropped. Overriding these is what makes the palette interactive.
final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


// MARK: - NSPanel controller

/// Manages the floating panel that hosts CommandPalette.
/// The panel uses a fixed 640pt width; height grows with SwiftUI content via sizingOptions.
final class PaletteController: NSObject, NSWindowDelegate {
    private var panel: CommandPanel?
    private var hostingController: NSHostingController<CommandPalette>?
    private let bridge: PythonBridge

    init(bridge: PythonBridge) {
        self.bridge = bridge
        super.init()
    }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }

        // Center horizontally; sit in the upper third of the screen (Spotlight-style)
        // rather than dead-center, which reads as more intentional and leaves room
        // for the result/waveform to grow downward.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                     ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let x = frame.origin.x + (frame.width - panel.frame.width) / 2
            let y = frame.origin.y + frame.height * 0.62
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Activate the app so the text field can receive keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        NotificationCenter.default.post(name: .paletteDidShow, object: nil)
        print("[Otto] palette shown")
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        print("[Otto] palette hidden")
    }

    private func buildPanel() {
        let p = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false      // SwiftUI .shadow handles it
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.animationBehavior = .none
        p.delegate = self

        let rootView = CommandPalette(bridge: bridge, onDismiss: { [weak self] in self?.hide() })
        let hosting = NSHostingController(rootView: rootView)
        // Let the hosting controller size the panel to fit SwiftUI content.
        hosting.sizingOptions = .preferredContentSize
        p.contentViewController = hosting

        hostingController = hosting
        panel = p
    }

    // MARK: - NSWindowDelegate

    /// Dismiss when focus leaves the palette (click-outside / app switch),
    /// matching the behavior users expect from Spotlight-style overlays.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
