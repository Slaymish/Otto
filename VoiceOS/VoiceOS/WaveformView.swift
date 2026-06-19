import SwiftUI

/// Scrolling waveform history — each frame shifts left and appends the new sample.
struct WaveformView: View {
    let level: Float
    let active: Bool

    private let barCount = 40
    @State private var history: [Float] = Array(repeating: 0, count: 40)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                drawBars(ctx: ctx, size: size)
            }
            .onChange(of: timeline.date) { _, _ in advance() }
        }
        .frame(height: 44)
    }

    // MARK: - Draw

    private func drawBars(ctx: GraphicsContext, size: CGSize) {
        let bw = size.width / CGFloat(barCount)
        let cy = size.height / 2
        for i in 0..<barCount {
            let lv = CGFloat(history[i])
            let envelope = 0.3 + 0.7 * (1.0 - abs(Double(i) - Double(barCount) / 2) / (Double(barCount) / 2))
            let barH = max(2.0, lv * CGFloat(envelope) * size.height * 0.75)
            let x = bw * CGFloat(i) + bw * 0.5
            var path = Path()
            path.move(to:    CGPoint(x: x, y: cy - barH / 2))
            path.addLine(to: CGPoint(x: x, y: cy + barH / 2))
            ctx.stroke(
                path,
                with: .color(.white.opacity(lv > 0.05 ? 0.9 : 0.2)),
                style: StrokeStyle(lineWidth: max(1.5, bw * 0.5), lineCap: .round)
            )
        }
    }

    // MARK: - State update (called at 30fps by TimelineView)

    private func advance() {
        let newSample: Float
        if active {
            newSample = level
        } else {
            // Exponential decay when idle
            newSample = (history.last ?? 0) * 0.8
        }
        history = Array(history.dropFirst()) + [newSample]
    }
}
