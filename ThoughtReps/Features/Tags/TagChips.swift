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

/// A named color a user can pick for a tag.
struct TagSwatch: Identifiable, Equatable {
    let name: String
    let hex: String

    var id: String { hex }
    var color: Color { Color(hex: hex) ?? .gray }
}

/// A tag's color: its saved hex, or a stable pick from a small palette.
enum TagColor {
    /// The first `automaticCount` swatches are the automatic palette; reordering or inserting
    /// among them shifts the automatic color of existing tags.
    static let swatches: [TagSwatch] = [
        TagSwatch(name: "Blue", hex: "#3352D1"),
        TagSwatch(name: "Teal", hex: "#1F8A70"),
        TagSwatch(name: "Copper", hex: "#B56629"),
        TagSwatch(name: "Purple", hex: "#7A4FC4"),
        TagSwatch(name: "Rose", hex: "#BF4066"),
        TagSwatch(name: "Steel Blue", hex: "#2E80AD"),
        TagSwatch(name: "Green", hex: "#3F8F3A"),
        TagSwatch(name: "Slate", hex: "#5F6B7A"),
    ]
    static let automaticCount = 6

    static let palette: [Color] = swatches.prefix(automaticCount).map(\.color)

    static func color(for tag: Tag) -> Color {
        if let hex = tag.colorHex, let color = Color(hex: hex) {
            return color
        }
        return automaticColor(for: tag)
    }

    static func automaticColor(for tag: Tag) -> Color {
        // Stable across launches (unlike `hashValue`).
        let sum = tag.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    /// "#RRGGBB" or "RRGGBB" in any case, as uppercase "#RRGGBB"; nil if it is neither.
    static func normalizedHex(_ hex: String) -> String? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + digits.uppercased()
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
