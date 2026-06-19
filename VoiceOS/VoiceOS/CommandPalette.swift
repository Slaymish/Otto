import SwiftUI
import AppKit

/// The floating command palette — text field + hold-to-talk mic button + waveform + result.
/// Hosted in a borderless NSPanel by PaletteController.
struct CommandPalette: View {
    // @Observable PythonBridge — SwiftUI tracks reads automatically, no wrapper needed.
    var bridge: PythonBridge

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

            if !bridge.spokenText.isEmpty {
                resultRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.waveformActive)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.spokenText.isEmpty)
        .frame(width: 640)
        // Liquid Glass background — native on macOS 26 (Tahoe).
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.clear)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .padding(1) // prevent shadow clipping
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear { textFieldFocused = true }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 12) {
            TextField("Ask anything…", text: $inputText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)
                .focused($textFieldFocused)
                .onSubmit { submitText() }

            micButton
        }
    }

    // MARK: - Mic button (hold to talk)

    private var micButton: some View {
        Image(systemName: isHoldingMic ? "waveform" : "mic")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isHoldingMic ? Color.white : Color.secondary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isHoldingMic ? Color.accentColor : Color.secondary.opacity(0.14))
            )
            .scaleEffect(isHoldingMic ? 1.12 : 1.0)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: isHoldingMic)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHoldingMic else { return }
                        isHoldingMic = true
                        bridge.sendVoiceStart()
                    }
                    .onEnded { _ in
                        guard isHoldingMic else { return }
                        isHoldingMic = false
                        bridge.sendVoiceStop()
                    }
            )
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
            Spacer()
        }
    }

    // MARK: - Actions

    private func submitText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        bridge.spokenText = ""
        bridge.sendText(text)
        inputText = ""
    }

    private func dismiss() {
        NSApp.keyWindow?.orderOut(nil)
    }
}


// MARK: - NSPanel controller

/// Manages the floating NSPanel that hosts CommandPalette.
/// The panel uses a fixed 640pt width; height grows with SwiftUI content via sizingOptions.
final class PaletteController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<CommandPalette>?
    private let bridge: PythonBridge

    init(bridge: PythonBridge) {
        self.bridge = bridge
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

        // Position: top-center of the primary screen, 12pt below the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.origin.x + (frame.width - panel.frame.width) / 2,
                y: frame.origin.y + frame.height - panel.frame.height - 12
            ))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false      // SwiftUI .shadow handles it
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true

        let hosting = NSHostingController(rootView: CommandPalette(bridge: bridge))
        // Let the hosting controller size the panel to fit SwiftUI content.
        hosting.sizingOptions = .preferredContentSize
        p.contentViewController = hosting

        hostingController = hosting
        panel = p
    }
}
