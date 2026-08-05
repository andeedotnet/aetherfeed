import SwiftUI

struct TagChipRow: View {
    let tags: [String]
    /// Advertorial chips are muted instead of tinted.
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(5), id: \.self) { tag in
                TagChip(name: tag, accent: accent)
            }
        }
    }
}

struct TagChip: View {
    let name: String
    var accent: Color = .accentColor

    var body: some View {
        Text(name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.15), in: Capsule())
            .foregroundStyle(accent)
            .lineLimit(1)
    }
}
