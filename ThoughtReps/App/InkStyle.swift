import SwiftUI
import UIKit

// "Ink, lighter": colors, fonts and card shapes shared across screens. Colors live in the asset
// catalog with dark variants; fonts are bundled (see ThoughtReps/Resources/Fonts) and scale with
// Dynamic Type.

// The tokens come from the current theme (AppTheme.swift) instead of the asset catalog.
@MainActor
extension Color {
    static var paper: Color { ThemeManager.shared.current.palette.paper }
    static var soft: Color { ThemeManager.shared.current.palette.soft }
    static var ink: Color { ThemeManager.shared.current.palette.ink }
    static var muted: Color { ThemeManager.shared.current.palette.muted }
    static var hl: Color { ThemeManager.shared.current.palette.hl }
    static var accent: Color { ThemeManager.shared.current.palette.accent }
    static var cardBorder: Color { ThemeManager.shared.current.palette.border }
}

// Ink keeps the system colors it used before themes; the others use their tokens.
@MainActor
extension Color {
    private static var isInk: Bool { ThemeManager.shared.current == .ink }
    static var subtle: Color { isInk ? .secondary : muted }
    static var surface: Color { isInk ? Color(.secondarySystemBackground) : soft }
    static var codeSpan: Color { isInk ? Color.secondary.opacity(0.15) : muted.opacity(0.2) }
}

@MainActor
extension ShapeStyle where Self == Color {
    static var paper: Color { Color.paper }
    static var soft: Color { Color.soft }
    static var ink: Color { Color.ink }
    static var muted: Color { Color.muted }
    static var hl: Color { Color.hl }
}

enum InkFontName {
    static let archivoSemiBold = "Archivo-SemiBold"
    static let archivoBold = "Archivo-Bold"
    static let archivoExtraBold = "Archivo-ExtraBold"
    static let monoRegular = "PaperMono-Regular"
    static let monoSemiBold = "PaperMono-SemiBold"
    /// Paper Mono has no italic; these are sheared copies made for emphasis in thought text.
    static let monoItalic = "PaperMono-Italic"
    static let monoSemiBoldItalic = "PaperMono-SemiBoldItalic"

    static let all = [archivoSemiBold, archivoBold, archivoExtraBold, monoRegular, monoSemiBold, monoItalic, monoSemiBoldItalic]
}

@MainActor
extension Font {
    /// The theme's title face (Archivo in Ink).
    static func archivo(_ size: CGFloat, weight: ArchivoWeight = .semibold, relativeTo style: Font.TextStyle = .headline) -> Font {
        ThemeManager.shared.current.title.font(size, weight: weight.themeWeight, relativeTo: style)
    }

    /// The theme's metadata face (Paper Mono in Ink), for small metadata only.
    static func mono(_ size: CGFloat = 11, semibold: Bool = false, relativeTo style: Font.TextStyle = .caption) -> Font {
        ThemeManager.shared.current.meta.font(size, weight: semibold ? .semibold : .regular, relativeTo: style)
    }

    /// Thought text (previews, snippets) in the font chosen in Settings, at a text style's size.
    static func thought(_ style: Font.TextStyle, size: CGFloat, font: ThoughtFont) -> Font {
        switch font {
        case .paperMono: .custom(InkFontName.monoRegular, size: size * ThoughtFont.monoScale, relativeTo: style)
        case .system: .system(style)
        }
    }

    enum ArchivoWeight {
        case semibold, bold, extrabold

        var fontName: String {
            switch self {
            case .semibold: InkFontName.archivoSemiBold
            case .bold: InkFontName.archivoBold
            case .extrabold: InkFontName.archivoExtraBold
            }
        }

        var themeWeight: ThemeFace.Weight {
            switch self {
            case .semibold: .semibold
            case .bold: .bold
            case .extrabold: .heavy
            }
        }
    }
}

/// Navigation bar titles in Archivo; the bars themselves stay native.
enum InkAppearance {
    @MainActor static func install() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let theme = ThemeManager.shared.current
        let ink = UIColor(theme.palette.ink)
        appearance.largeTitleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: theme.title.uiFont(32, weight: .heavy)),
            .foregroundColor: ink,
        ]
        appearance.titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: theme.title.uiFont(17, weight: .semibold)),
            .foregroundColor: ink,
        ]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.compactAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        // Appearance proxies only reach new bars; restyle the ones already on screen.
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                restyle(window, with: appearance)
            }
        }
    }

    private static func restyle(_ view: UIView, with appearance: UINavigationBarAppearance) {
        if let bar = view as? UINavigationBar {
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }
        view.subviews.forEach { restyle($0, with: appearance) }
    }
}

private struct InkCard: ViewModifier {
    var filled: Bool

    func body(content: Content) -> some View {
        let shape = ThemeManager.shared.current.card
        let filled = filled || shape.alwaysFilled
        let rect = RoundedRectangle(cornerRadius: shape.cornerRadius)
        content
            .padding(14)
            .background(rect.fill(filled ? Color.soft : Color.paper))
            .overlay {
                if !filled || shape.hardShadow > 0 {
                    rect.strokeBorder(Color.cardBorder, lineWidth: shape.borderWidth)
                }
            }
            .background {
                if shape.hardShadow > 0 {
                    rect.fill(Color.cardBorder).offset(x: shape.hardShadow, y: shape.hardShadow)
                }
            }
    }
}

/// Press feedback for cards and ink buttons: a slight shrink plus an ink wash over the shape.
@MainActor
struct InkPressStyle: ButtonStyle {
    var cornerRadius: CGFloat?
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? ThemeManager.shared.current.card.cornerRadius)
        configuration.label
            .contentShape(shape)
            .overlay {
                shape.fill(Color.ink.opacity(configuration.isPressed ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.2), value: configuration.isPressed)
    }
}

extension View {
    /// A 12pt-radius card with a 1pt `hl` border and no shadow; `filled` swaps the border for a soft fill.
    func inkCard(filled: Bool = false) -> some View {
        modifier(InkCard(filled: filled))
    }

    /// A plain list on a paper background.
    func inkList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
    }

    /// A list row that is just its card: no separator, no row background, no disclosure chevron.
    /// The press style replaces the row highlight, which the clear background would hide.
    func inkRow() -> some View {
        buttonStyle(InkPressStyle())
            .navigationLinkIndicatorVisibility(.hidden)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    /// Section header in Paper Mono.
    func inkSectionHeader() -> some View {
        font(.mono(12))
            .foregroundStyle(Color.muted)
            .textCase(nil)
    }
}

/// A small Paper Mono status badge.
struct InkBadge: View {
    enum Style {
        case overdue, today, plain
    }

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.mono(11, semibold: style != .plain))
            .foregroundStyle(style == .overdue ? Color.paper : style == .today ? Color.ink : Color.muted)
            .padding(.horizontal, style == .plain ? 0 : 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    style == .overdue ? Color.ink : style == .today ? Color.hl : Color.clear
                )
            )
    }
}

/// Thought text (previews, snippets) in the typeface chosen in Settings.
struct ThoughtTextFont: ViewModifier {
    let style: Font.TextStyle
    let size: CGFloat
    @AppStorage(AppSettings.Key.thoughtFont) private var font = ThoughtFont.paperMono

    func body(content: Content) -> some View {
        content.font(.thought(style, size: size, font: font))
    }
}

extension View {
    /// `size` is the text style's default point size (subheadline is 15).
    func thoughtTextFont(_ style: Font.TextStyle = .subheadline, size: CGFloat = 15) -> some View {
        modifier(ThoughtTextFont(style: style, size: size))
    }
}
