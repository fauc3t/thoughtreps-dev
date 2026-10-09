import SwiftUI

/// A theme list. Each row previews its theme with that theme's own colors, fonts and card shape;
/// tapping applies it.
struct ThemePickerView: View {
    @State private var themes = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { themes.current = theme }
                    } label: {
                        ThemePreviewCard(theme: theme, selected: themes.current == theme)
                    }
                    .buttonStyle(.plain)
                }
                Text("Themes change colors, title fonts and cards. Your thought text font is set under Appearance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color.paper)
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemePreviewCard: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        let palette = theme.palette
        let card = theme.card
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.name)
                    .font(theme.title.font(22, weight: .heavy, relativeTo: .title2))
                    .foregroundStyle(palette.ink)
                Spacer()
                if selected {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(theme.meta.font(12, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(palette.accent)
                }
            }
            Text(theme.tagline)
                .font(theme.meta.font(12, weight: .regular, relativeTo: .caption))
                .foregroundStyle(palette.muted)

            sampleThought(palette: palette, card: card)
            pinned(palette: palette, card: card)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(palette.paper))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(selected ? palette.accent : palette.hl, lineWidth: selected ? 3 : 1)
        )
        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name). \(theme.tagline)")
        .accessibilityValue(selected ? "In use" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @Environment(\.colorScheme) private var systemScheme

    private func sampleThought(palette: ThemePalette, card: CardShape) -> some View {
        let rect = RoundedRectangle(cornerRadius: card.cornerRadius)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Second-order thinking")
                    .font(theme.title.font(17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(palette.ink)
                Spacer()
                Text("due today")
                    .font(theme.meta.font(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.hl))
            }
            Text("And then what? Ask it twice before you decide.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .lineLimit(2)
            Text("#decisions")
                .font(theme.meta.font(11, weight: .regular, relativeTo: .caption))
                .foregroundStyle(palette.accent)
        }
        .padding(14)
        .background(rect.fill(card.alwaysFilled ? palette.soft : palette.paper))
        .overlay {
            if !card.alwaysFilled || card.hardShadow > 0 {
                rect.strokeBorder(palette.border, lineWidth: card.borderWidth)
            }
        }
        .background {
            if card.hardShadow > 0 {
                rect.fill(palette.border).offset(x: card.hardShadow, y: card.hardShadow)
            }
        }
    }

    private func pinned(palette: ThemePalette, card: CardShape) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(palette.muted)
            Text("Morning pages")
                .font(theme.title.font(16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(palette.ink)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: card.cornerRadius).fill(palette.soft))
    }
}
