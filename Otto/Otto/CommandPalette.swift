import SwiftUI
import AppKit

private extension Notification.Name {
    static let paletteDidShow = Notification.Name("OttoPaletteDidShow")
}

private enum SuggestionKind {
    case recent(phrase: String, count: Int)
    case capability(JournalCard)
    case openJournal
}

private struct SuggestionItem: Identifiable {
    let id: String
    let label: String
    let hint: String?
    let icon: String
    let badge: Int
    let isNew: Bool
    let kind: SuggestionKind
}

/// How long a spoken result lingers before it auto-clears (seconds).
private let resultLingerSeconds: UInt64 = 8

/// The floating command palette — text field + hold-to-talk mic button + waveform + result.
/// Hosted in a borderless `CommandPanel` by `PaletteController`.
struct CommandPalette: View {
    // any OttoBridge — tracks both PythonBridge and OttoEngine via Observable existential.
    var bridge: any OttoBridge
    var onDismiss: () -> Void = {}
    var onOpenJournal: () -> Void = {}

    @State private var inputText = ""
    @State private var isListening = false
    @State private var selectedIndex: Int? = nil
    @FocusState private var textFieldFocused: Bool

    /// Orb mode when nothing has been typed; bar mode as soon as text exists.
    private var isOrbMode: Bool { inputText.isEmpty }

    var body: some View {
        Group {
            if isOrbMode {
                orbModeView
            } else {
                barModeView
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.12), value: isOrbMode)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.waveformActive)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.spokenText)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.lastError)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.learnedEvent)
        .animation(.spring(duration: 0.22, bounce: 0.05), value: showSuggestions)
        .background { paletteBackground }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .padding(1) // prevent shadow clipping
        .onKeyPress(.escape) { stopListening(); onDismiss(); return .handled }
        .onAppear { textFieldFocused = true; startListeningIfEnabled() }
        .onReceive(NotificationCenter.default.publisher(for: .paletteDidShow)) { _ in
            inputText = ""
            selectedIndex = nil
            textFieldFocused = true
            bridge.requestJournal()
            bridge.requestSuggestions()
            startListeningIfEnabled()
        }
        .onChange(of: inputText) { selectedIndex = nil }
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

    // MARK: - Orb mode

    private var orbModeView: some View {
        ZStack {
            CapabilityHalo(items: haloItems, orbDiameter: 140, onSelect: handleHalo)
            OrbView(listening: isListening,
                    level: bridge.micLevel,
                    micEnabled: true,
                    onTap: toggleListening)
            // Invisible, focused field that captures the first keystroke to enter bar mode.
            TextField("", text: $inputText)
                .textFieldStyle(.plain)
                .focused($textFieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onSubmit { submitText() }
        }
        .padding(20)
    }

    // MARK: - Bar mode

    private var barModeView: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if bridge.waveformActive || isListening {
                WaveformView(level: bridge.micLevel, active: bridge.waveformActive)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let error = bridge.lastError {
                errorRow(error)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !bridge.spokenText.isEmpty {
                resultRow
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let learned = bridge.learnedEvent {
                learnedChip(learned)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showSuggestions {
                suggestionSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: 640)
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
                .onKeyPress(.upArrow) {
                    guard showSuggestions else { return .ignored }
                    if let idx = selectedIndex { selectedIndex = max(0, idx - 1) }
                    else { selectedIndex = suggestions.count - 1 }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard showSuggestions else { return .ignored }
                    if let idx = selectedIndex { selectedIndex = min(suggestions.count - 1, idx + 1) }
                    else { selectedIndex = 0 }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let idx = selectedIndex, idx < suggestions.count else { return .ignored }
                    handleSelect(suggestions[idx])
                    return .handled
                }

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
        Image(systemName: isListening ? "waveform" : "mic.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isListening ? Color.white : Color.secondary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isListening ? Color.accentColor : Color.secondary.opacity(0.14))
            )
            .scaleEffect(isListening ? 1.12 : 1.0)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: isListening)
            .contentShape(Circle())
            .onTapGesture { toggleListening() }
            .help(isListening ? "Tap to stop" : "Tap to talk")
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

    @ViewBuilder private var paletteBackground: some View {
        #if HAS_MACOS26_SDK
        if #available(macOS 26.0, *) {
            glassBackground
        } else {
            materialBackground
        }
        #else
        materialBackground
        #endif
    }

    #if HAS_MACOS26_SDK
    @available(macOS 26.0, *)
    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.clear)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    #endif

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
        stopListening()
    }

    private func startListeningIfEnabled() {
        if SettingsStore.shared.micAutoStart && !isListening {
            isListening = true
            bridge.lastError = nil
            bridge.sendVoiceStart()
        }
    }

    private func toggleListening() {
        isListening.toggle()
        bridge.lastError = nil
        if isListening { bridge.sendVoiceStart() } else { bridge.sendVoiceStop() }
    }

    private func stopListening() {
        if isListening { isListening = false; bridge.sendVoiceStop() }
    }

    private func handleHalo(_ item: HaloItem) {
        if item.isParameterized {
            inputText = item.phrase
            textFieldFocused = true
        } else {
            bridge.spokenText = ""
            bridge.lastError = nil
            bridge.sendText(item.phrase)
        }
    }

    private var haloItems: [HaloItem] {
        let recent = bridge.recentPhrases.prefix(2).map { rp in
            HaloItem(id: "recent::\(rp.phrase)", label: rp.phrase,
                     icon: "clock.arrow.circlepath", phrase: rp.phrase, isParameterized: false)
        }
        let recentSet = Set(bridge.recentPhrases.map { $0.phrase.lowercased() })
        let caps = bridge.journalCards
            .filter { !recentSet.contains($0.description.lowercased()) }
            .sorted { $0.timesUsed != $1.timesUsed ? $0.timesUsed > $1.timesUsed : $0.confidence > $1.confidence }
            .prefix(5 - recent.count)
            .map { card in
                HaloItem(id: "cap::\(card.id)", label: card.description,
                         icon: Self.primitiveIcon(card.primitive), phrase: card.description,
                         isParameterized: CapabilityKind.isParameterized(template: card.template))
            }
        return Array(recent) + Array(caps)
    }

    private func handleSelect(_ item: SuggestionItem) {
        selectedIndex = nil
        switch item.kind {
        case .recent(let phrase, _):
            bridge.spokenText = ""
            bridge.lastError = nil
            bridge.sendText(phrase)
            inputText = ""
        case .capability(let card):
            bridge.spokenText = ""
            bridge.lastError = nil
            bridge.sendText(card.description)
            inputText = ""
        case .openJournal:
            onOpenJournal()
        }
    }

    // MARK: - Suggestions

    private var showSuggestions: Bool {
        !bridge.waveformActive && !isListening &&
        bridge.spokenText.isEmpty && bridge.lastError == nil &&
        bridge.learnedEvent == nil && !suggestions.isEmpty
    }

    private var suggestions: [SuggestionItem] {
        let q = inputText.lowercased().trimmingCharacters(in: .whitespaces)
        var items: [SuggestionItem] = []

        if q.isEmpty {
            let recentItems = bridge.recentPhrases.prefix(3).map { rp in
                SuggestionItem(
                    id: "recent::\(rp.phrase)",
                    label: rp.phrase,
                    hint: "recent",
                    icon: "clock.arrow.circlepath",
                    badge: rp.count,
                    isNew: false,
                    kind: .recent(phrase: rp.phrase, count: rp.count)
                )
            }
            items.append(contentsOf: recentItems)

            let recentSet = Set(bridge.recentPhrases.map { $0.phrase.lowercased() })
            let capSlots = max(0, 5 - items.count)
            let filteredCaps = bridge.journalCards.filter { !recentSet.contains($0.description.lowercased()) }
            let sortedCaps = filteredCaps.sorted { a, b in
                a.timesUsed != b.timesUsed ? a.timesUsed > b.timesUsed : a.confidence > b.confidence
            }
            let capItems: [SuggestionItem] = Array(sortedCaps.prefix(capSlots)).map { card in
                SuggestionItem(
                    id: "cap::\(card.id)",
                    label: card.description,
                    hint: card.examples.first,
                    icon: Self.primitiveIcon(card.primitive),
                    badge: card.timesUsed,
                    isNew: card.origin == "learned",
                    kind: .capability(card)
                )
            }
            items.append(contentsOf: capItems)

            items.append(SuggestionItem(
                id: "__journal__",
                label: "Open Journal",
                hint: "Browse and edit what Otto knows",
                icon: "book.closed",
                badge: 0,
                isNew: false,
                kind: .openJournal
            ))
        } else {
            let matchedCaps = bridge.journalCards.filter { card in
                card.description.lowercased().contains(q) ||
                card.examples.contains { $0.lowercased().contains(q) }
            }
            let sortedMatchedCaps = matchedCaps.sorted { $0.timesUsed > $1.timesUsed }
            let capItems: [SuggestionItem] = Array(sortedMatchedCaps.prefix(5)).map { card in
                SuggestionItem(
                    id: "cap::\(card.id)",
                    label: card.description,
                    hint: card.examples.first(where: { $0.lowercased().contains(q) }),
                    icon: Self.primitiveIcon(card.primitive),
                    badge: card.timesUsed,
                    isNew: card.origin == "learned",
                    kind: .capability(card)
                )
            }
            items.append(contentsOf: capItems)

            let recentItems = bridge.recentPhrases
                .filter { $0.phrase.lowercased().contains(q) }
                .prefix(max(0, 6 - items.count))
                .map { rp in
                    SuggestionItem(
                        id: "recent::\(rp.phrase)",
                        label: rp.phrase,
                        hint: nil,
                        icon: "clock.arrow.circlepath",
                        badge: rp.count,
                        isNew: false,
                        kind: .recent(phrase: rp.phrase, count: rp.count)
                    )
                }
            items.append(contentsOf: recentItems)
        }

        return Array(items.prefix(6))
    }

    @ViewBuilder private var suggestionSection: some View {
        Divider()
            .padding(.horizontal, 2)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                    suggestionRow(item, isSelected: selectedIndex == index)
                        .contentShape(Rectangle())
                        .onTapGesture { handleSelect(item) }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 252)
        .padding(.bottom, 6)
    }

    private func suggestionRow(_ item: SuggestionItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    if item.isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : .white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                isSelected ? Color.white.opacity(0.3) : Color.accentColor,
                                in: Capsule()
                            )
                    }
                    Spacer(minLength: 0)
                    if item.badge > 0 {
                        Text("\(item.badge)\u{d7}")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    }
                }
                if let hint = item.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 8)
            }
        }
    }

    private static func primitiveIcon(_ primitive: String) -> String {
        switch primitive {
        case "run_applescript": return "terminal"
        case "press_key":       return "keyboard"
        case "read_screen":     return "eye"
        case "open_url":        return "link"
        case "obs_call":        return "record.circle"
        default:                return "sparkles"
        }
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
    private let bridge: any OttoBridge
    /// Set by AppDelegate after both controllers exist; forwarded into CommandPalette
    /// so the "Edit" button in the learned-nudge chip can open the journal window.
    var onOpenJournal: () -> Void = {}

    init(bridge: any OttoBridge) {
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

        let rootView = CommandPalette(
            bridge: bridge,
            onDismiss: { [weak self] in self?.hide() },
            onOpenJournal: { [weak self] in self?.onOpenJournal() }
        )
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
