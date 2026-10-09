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
        HStack(spacing: 5) {
            Circle()
                .fill(TagColor.color(for: tag))
                .frame(width: 5, height: 5)
            Text("#\(tag.displayName)")
                .font(.mono(11))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(ThemeManager.shared.current.card.alwaysFilled ? Color.hl : Color.soft))
        .foregroundStyle(Color.ink)
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

    /// sRGB components in 0...1 (out-of-range values, e.g. from Display P3, are clamped) as "#RRGGBB".
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// A picked color as "#RRGGBB" in sRGB, ignoring alpha; nil if it can't be converted.
    static func hex(for color: UIColor) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3
        else { return nil }
        return hex(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
    }

    /// Black on light colors (a custom pick can be near white), white otherwise.
    static func checkmarkColor(onHex hex: String?) -> Color {
        guard let digits = hex.flatMap(normalizedHex)?.dropFirst(),
              let value = UInt32(digits, radix: 16) else { return .white }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.7 ? .black : .white
    }

    /// True when a saved color is neither "Automatic" nor one of the swatches.
    static func isCustom(_ hex: String?) -> Bool {
        guard let normalized = hex.flatMap(normalizedHex) else { return false }
        return !swatches.contains { $0.hex == normalized }
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
