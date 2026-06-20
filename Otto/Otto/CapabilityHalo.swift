import SwiftUI

/// One floating capability chip around the orb.
struct HaloItem: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String
    let phrase: String          // text sent or pre-filled when tapped
    let isParameterized: Bool   // true → pre-fill input; false → run immediately
}

/// Lays out capability chips radially around the orb. Purely presentational —
/// the parent owns selection behavior.
struct CapabilityHalo: View {
    let items: [HaloItem]
    let orbDiameter: CGFloat
    var onSelect: (HaloItem) -> Void

    /// Distance from center to each chip's center.
    private var radius: CGFloat { orbDiameter / 2 + 64 }

    var body: some View {
        ZStack {
            ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                chip(item)
                    .offset(offset(for: index, of: min(items.count, 5)))
            }
        }
        // Canvas large enough to hold the orb + chips on all sides.
        .frame(width: radius * 2 + 140, height: radius * 2 + 80)
    }

    private func chip(_ item: HaloItem) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 160)
    }

    /// Distribute chips evenly around the circle, starting at the top.
    private func offset(for index: Int, of count: Int) -> CGSize {
        guard count > 0 else { return .zero }
        let angle = -Double.pi / 2 + (Double(index) / Double(count)) * 2 * .pi
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}
