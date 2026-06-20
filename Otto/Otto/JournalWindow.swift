import SwiftUI
import AppKit

// MARK: - Window controller

/// Manages the "Otto — Journal" window: a standard resizable NSWindow showing
/// every capability Otto knows, with edit/delete affordances for learned entries.
/// Opened by ⌥⇧Space or the "Edit" button in the learned-nudge chip.
@MainActor
final class JournalController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let bridge: OttoEngine

    init(bridge: OttoEngine) {
        self.bridge = bridge
        super.init()
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil { buildWindow() }
        bridge.requestJournal()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Otto \u{2014} Journal"
        w.minSize = NSSize(width: 480, height: 320)
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: JournalView(bridge: bridge))
        window = w
    }
}

// MARK: - Journal view

struct JournalView: View {
    var bridge: OttoEngine

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if bridge.journalCards.isEmpty {
                emptyState
            } else {
                cardList
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { bridge.requestJournal() }
    }

    private var headerBar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capability Journal")
                    .font(.headline)
                if let h = bridge.journalHeader {
                    Text("\(h.learned) learned · \(h.capabilities) total · \(h.commands) commands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Refresh") { bridge.requestJournal() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(bridge.journalCards) { card in
                    JournalCardRow(card: card, bridge: bridge)
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Nothing in the journal yet.")
                .foregroundStyle(.secondary)
            Text("Otto adds entries here after learning new phrases from your sessions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card row

struct JournalCardRow: View {
    let card: JournalCard
    var bridge: OttoEngine

    @State private var isEditing = false
    @State private var editDesc = ""
    @State private var editExamples = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            if !card.examples.isEmpty {
                WrappedTagsView(tags: card.examples)
            }
            metaRow
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .sheet(isPresented: $isEditing) {
            EditCapabilitySheet(
                description: $editDesc,
                examples: $editExamples,
                onSave: {
                    let exArr = editExamples
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    bridge.editCapability(card.id, description: editDesc, examples: exArr)
                    isEditing = false
                    bridge.requestJournal()
                },
                onCancel: { isEditing = false }
            )
        }
    }

    private var topRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if card.origin == "learned" {
                        Text("LEARNED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Text(card.description)
                        .font(.system(size: 13, weight: .medium))
                }
                ConfidenceBar(score: card.confidence)
            }
            Spacer(minLength: 16)
            if card.origin == "learned" {
                actionButtons
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Edit") {
                editDesc = card.description
                editExamples = card.examples.joined(separator: "\n")
                isEditing = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Delete") {
                bridge.deleteCapability(card.id)
                bridge.requestJournal()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red.opacity(0.75))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            Label(card.primitive, systemImage: "terminal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let at = card.learnedAt {
                Text(at.prefix(10))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if card.timesUsed > 0 {
                Text("Used \(card.timesUsed)\u{d7}")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Confidence bar

struct ConfidenceBar: View {
    let score: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * max(0, min(1, score)))
                }
            }
            .frame(width: 72, height: 4)
            Text(String(format: "%.0f%%", score * 100))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var barColor: Color {
        score >= 0.7 ? .green : score >= 0.4 ? .orange : .red
    }
}

// MARK: - Wrapped tags

struct WrappedTagsView: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text("\u{201C}\(tag)\u{201D}")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlColor), in: Capsule())
            }
        }
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                x = 0; y += lineH + spacing; lineH = 0
            }
            lineH = max(lineH, sz.height)
            x += sz.width + spacing
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineH + spacing; lineH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            lineH = max(lineH, sz.height)
            x += sz.width + spacing
        }
    }
}

// MARK: - Edit sheet

struct EditCapabilitySheet: View {
    @Binding var description: String
    @Binding var examples: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Capability").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.body)
                    .frame(minHeight: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Example phrases (one per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $examples)
                    .font(.body)
                    .frame(minHeight: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 380, idealWidth: 420)
    }
}
