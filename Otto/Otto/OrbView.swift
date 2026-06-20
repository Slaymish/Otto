import SwiftUI

/// The circular palette orb: shows a radial waveform while listening, a mic glyph
/// when idle/disabled, and a subtle breathing pulse. Tapping toggles listening.
struct OrbView: View {
    let listening: Bool
    let level: Float
    let micEnabled: Bool
    var onTap: () -> Void

    private let diameter: CGFloat = 140

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)

            if listening {
                RadialWaveform(level: level)
                    .padding(26)
            } else {
                Image(systemName: micEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(listening ? 1.0 : 0.98)
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: listening)
        .contentShape(Circle())
        .onTapGesture { onTap() }
        .help(listening ? "Listening — tap to stop" : "Tap to talk")
    }
}

/// A ring of bars whose heights track the live mic level — the circular analog of WaveformView.
private struct RadialWaveform: View {
    let level: Float
    private let bars = 36
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseR = min(size.width, size.height) / 2 - 8
                for i in 0..<bars {
                    let angle = (Double(i) / Double(bars)) * 2 * .pi
                    // Animated, level-scaled bar length with a little per-bar variation.
                    let wobble = 0.5 + 0.5 * sin(phase * 2 + Double(i) * 0.5)
                    let len = 4 + CGFloat(level) * 22 * CGFloat(wobble)
                    let inner = CGPoint(x: c.x + cos(angle) * baseR, y: c.y + sin(angle) * baseR)
                    let outer = CGPoint(x: c.x + cos(angle) * (baseR + len), y: c.y + sin(angle) * (baseR + len))
                    var path = Path()
                    path.move(to: inner)
                    path.addLine(to: outer)
                    ctx.stroke(path, with: .color(.white.opacity(level > 0.05 ? 0.85 : 0.25)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            .onChange(of: timeline.date) { _, _ in phase += 0.08 }
        }
    }
}
