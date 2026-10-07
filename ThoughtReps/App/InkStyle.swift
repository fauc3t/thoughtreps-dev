import SwiftUI
import UIKit

// "Ink, lighter": colors, fonts and card shapes shared across screens. Colors live in the asset
// catalog with dark variants; fonts are bundled (see ThoughtReps/Resources/Fonts) and scale with
// Dynamic Type.

extension Color {
    static let paper = Color("Paper")
    static let soft = Color("Soft")
    static let ink = Color("Ink")
    static let muted = Color("Muted")
    static let hl = Color("Hl")
}

extension ShapeStyle where Self == Color {
    static var paper: Color { .paper }
    static var soft: Color { .soft }
    static var ink: Color { .ink }
    static var muted: Color { .muted }
    static var hl: Color { .hl }
}

enum InkFontName {
    static let archivoSemiBold = "Archivo-SemiBold"
    static let archivoBold = "Archivo-Bold"
    static let archivoExtraBold = "Archivo-ExtraBold"
    static let monoRegular = "PaperMono-Regular"
    static let monoSemiBold = "PaperMono-SemiBold"

    static let all = [archivoSemiBold, archivoBold, archivoExtraBold, monoRegular, monoSemiBold]
}

extension Font {
    /// Archivo, for titles.
    static func archivo(_ size: CGFloat, weight: ArchivoWeight = .semibold, relativeTo style: Font.TextStyle = .headline) -> Font {
        .custom(weight.fontName, size: size, relativeTo: style)
    }

    /// Paper Mono, for small metadata only.
    static func mono(_ size: CGFloat = 11, semibold: Bool = false, relativeTo style: Font.TextStyle = .caption) -> Font {
        .custom(semibold ? InkFontName.monoSemiBold : InkFontName.monoRegular, size: size, relativeTo: style)
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
    }
}

/// Navigation bar titles in Archivo; the bars themselves stay native.
enum InkAppearance {
    @MainActor static func install() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let ink = UIColor(named: "Ink") ?? .label
        appearance.largeTitleTextAttributes = [
            .font: scaled(InkFontName.archivoExtraBold, size: 32, style: .largeTitle),
            .foregroundColor: ink,
        ]
        appearance.titleTextAttributes = [
            .font: scaled(InkFontName.archivoSemiBold, size: 17, style: .headline),
            .foregroundColor: ink,
        ]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.compactAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }

    private static func scaled(_ name: String, size: CGFloat, style: UIFont.TextStyle) -> UIFont {
        let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .bold)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }
}

private struct InkCard: ViewModifier {
    var filled: Bool

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(filled ? Color.soft : Color.paper)
            )
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hl, lineWidth: 1)
                }
            }
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
    func inkRow() -> some View {
        navigationLinkIndicatorVisibility(.hidden)
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
