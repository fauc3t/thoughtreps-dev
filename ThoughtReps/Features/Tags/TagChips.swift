import SwiftUI

/// A row of `#tag` chips. `linked` chips push the tag's timeline; use `false` inside
/// rows that are already a NavigationLink.
struct TagChips: View {
    let tags: [Tag]
    var linked: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags) { tag in
                if linked {
                    NavigationLink(value: tag) { chip(tag) }
                        .buttonStyle(.plain)
                } else {
                    chip(tag)
                }
            }
        }
    }

    private func chip(_ tag: Tag) -> some View {
        Text("#\(tag.displayName)")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TagColor.color(for: tag).opacity(0.15))
            )
            .foregroundStyle(.primary)
    }
}

/// A tag's color: its saved hex, or a stable pick from a small palette.
enum TagColor {
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.32, blue: 0.82),
        Color(red: 0.12, green: 0.54, blue: 0.44),
        Color(red: 0.71, green: 0.40, blue: 0.16),
        Color(red: 0.48, green: 0.31, blue: 0.77),
        Color(red: 0.75, green: 0.25, blue: 0.40),
        Color(red: 0.18, green: 0.50, blue: 0.68),
    ]

    static func color(for tag: Tag) -> Color {
        if let hex = tag.colorHex, let color = Color(hex: hex) {
            return color
        }
        // Stable across launches (unlike `hashValue`).
        let sum = tag.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

extension Color {
    /// Parses "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
