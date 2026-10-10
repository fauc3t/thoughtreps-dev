import SwiftUI
import UIKit

// Swappable themes. A theme replaces the Ink color tokens, the title and metadata typefaces, and
// the card shape. Body text keeps the Settings font choice.

/// One theme's color tokens, each with a light and dark value.
struct ThemePalette {
    let paper: Color
    let soft: Color
    let ink: Color
    let muted: Color
    let hl: Color
    let accent: Color
    /// Card outlines; usually `hl`, but bolder themes outline in ink.
    let border: Color

    init(paper: (String, String), soft: (String, String), ink: (String, String), muted: (String, String),
         hl: (String, String), accent: (String, String), border: (String, String)? = nil) {
        self.paper = Self.dynamic(paper)
        self.soft = Self.dynamic(soft)
        self.ink = Self.dynamic(ink)
        self.muted = Self.dynamic(muted)
        self.hl = Self.dynamic(hl)
        self.accent = Self.dynamic(accent)
        self.border = Self.dynamic(border ?? hl)
    }

    private static func dynamic(_ pair: (light: String, dark: String)) -> Color {
        let light = UIColor(Color(hex: pair.light) ?? .black)
        let dark = UIColor(Color(hex: pair.dark) ?? .white)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// A typeface family at three weights, either bundled or built into iOS, or a system design.
enum ThemeFace {
    case custom(regular: String, semibold: String, bold: String, heavy: String)
    case system(Font.Design)

    enum Weight { case regular, semibold, bold, heavy }

    func font(_ size: CGFloat, weight: Weight, relativeTo style: Font.TextStyle) -> Font {
        switch self {
        case let .custom(regular, semibold, bold, heavy):
            let name = [regular, semibold, bold, heavy][weight.index]
            return .custom(name, size: size, relativeTo: style)
        case .system(let design):
            return .system(style, design: design).weight(weight.fontWeight)
        }
    }

    func uiFont(_ size: CGFloat, weight: Weight) -> UIFont {
        switch self {
        case let .custom(regular, semibold, bold, heavy):
            let name = [regular, semibold, bold, heavy][weight.index]
            return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .bold)
        case .system(let design):
            let base = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
            let uiDesign: UIFontDescriptor.SystemDesign = switch design {
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            default: .default
            }
            return base.fontDescriptor.withDesign(uiDesign).map { UIFont(descriptor: $0, size: size) } ?? base
        }
    }

    /// The PostScript name for MarkdownUI headings, or nil for a system design.
    func customName(_ weight: Weight) -> String? {
        guard case let .custom(regular, semibold, bold, heavy) = self else { return nil }
        return [regular, semibold, bold, heavy][weight.index]
    }

    var systemDesign: Font.Design? {
        if case .system(let design) = self { design } else { nil }
    }
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension ThemeFace.Weight {
    var index: Int {
        switch self {
        case .regular: 0
        case .semibold: 1
        case .bold: 2
        case .heavy: 3
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

struct CardShape {
    var cornerRadius: CGFloat = 12
    var borderWidth: CGFloat = 1
    /// Every card gets the soft fill instead of an outline.
    var alwaysFilled = false
    /// A hard, unblurred offset shadow in ink.
    var hardShadow: CGFloat = 0
}

/// Swipe action backgrounds; the labels on them are always white.
struct SwipeTints {
    let pin: Color
    let tomorrow: Color
    let archive: Color

    init(pin: String, tomorrow: String, archive: String) {
        self.init(pin: Color(hex: pin) ?? .gray, tomorrow: Color(hex: tomorrow) ?? .gray, archive: Color(hex: archive) ?? .gray)
    }

    init(pin: Color, tomorrow: Color, archive: Color) {
        self.pin = pin
        self.tomorrow = tomorrow
        self.archive = archive
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case ink, library, midnight, garden, terminal, pop

    var id: Self { self }

    var name: String {
        switch self {
        case .ink: "Ink"
        case .library: "Library"
        case .midnight: "Midnight"
        case .garden: "Garden"
        case .terminal: "Terminal"
        case .pop: "Pop"
        }
    }

    var tagline: String {
        switch self {
        case .ink: "Clean outlines, Archivo and Paper Mono."
        case .library: "Warm paper, old-style serifs, oxblood ink."
        case .midnight: "Deep navy and gold, always dark."
        case .garden: "Soft sage, rounded type, pillowy cards."
        case .terminal: "Green phosphor on black. Menlo everywhere."
        case .pop: "Cream, coral and thick ink outlines."
        }
    }

    /// Themes that only make sense in one appearance force it.
    var colorScheme: ColorScheme? {
        switch self {
        case .midnight, .terminal: .dark
        default: nil
        }
    }

    var palette: ThemePalette {
        switch self {
        case .ink: Self.inkPalette
        case .library: Self.libraryPalette
        case .midnight: Self.midnightPalette
        case .garden: Self.gardenPalette
        case .terminal: Self.terminalPalette
        case .pop: Self.popPalette
        }
    }

    // Matches the asset catalog's Ink colors.
    private static let inkPalette = ThemePalette(paper: ("FFFFFF", "111214"), soft: ("F2F2F0", "1D1E22"), ink: ("111214", "F2F2EF"),
                           muted: ("5E6066", "A3A5AC"), hl: ("E4E4E0", "34353A"), accent: ("111214", "F2F2EF"))
    private static let libraryPalette = ThemePalette(paper: ("F6EFE2", "1E1A15"), soft: ("ECE2CE", "2A241C"), ink: ("2B2118", "EFE5D3"),
                               muted: ("7A6A55", "A8987F"), hl: ("DDCFB6", "3D3428"), accent: ("8B3A1F", "D98B5F"))
    private static let midnightPalette = ThemePalette(paper: ("0E1424", "0E1424"), soft: ("182038", "182038"), ink: ("ECE8DC", "ECE8DC"),
                                muted: ("8A93AD", "8A93AD"), hl: ("2A3452", "2A3452"), accent: ("E9C46A", "E9C46A"))
    private static let gardenPalette = ThemePalette(paper: ("F3F5EE", "121611"), soft: ("E4EADA", "1D2419"), ink: ("1F2A1C", "E4EBDD"),
                              muted: ("66735F", "97A48F"), hl: ("CBD6BC", "2F3A29"), accent: ("3F7D4E", "8CC79A"))
    private static let terminalPalette = ThemePalette(paper: ("050805", "050805"), soft: ("0D160E", "0D160E"), ink: ("7CFC8A", "7CFC8A"),
                                muted: ("4C9A57", "4C9A57"), hl: ("1D3A21", "1D3A21"), accent: ("B6FFBE", "B6FFBE"),
                                border: ("2E6B36", "2E6B36"))
    private static let popPalette = ThemePalette(paper: ("FFF6E3", "17140F"), soft: ("FFE7B0", "2B2516"), ink: ("141210", "FFF6E3"),
                           muted: ("5A5246", "BDB29E"), hl: ("FFD36B", "4A3F22"), accent: ("F2542D", "FF7A59"),
                           border: ("141210", "FFF6E3"))

    /// Pin, unpin and restore share `pin`.
    var swipe: SwipeTints {
        switch self {
        case .ink: SwipeTints(pin: palette.accent, tomorrow: .orange, archive: .gray)
        case .library: SwipeTints(pin: "8B3A1F", tomorrow: "A0642A", archive: "7A6A55")
        case .midnight: SwipeTints(pin: "8A6810", tomorrow: "3B4F86", archive: "4B5675")
        case .garden: SwipeTints(pin: "2F6B3F", tomorrow: "56722E", archive: "66735F")
        case .terminal: SwipeTints(pin: "1F7A2E", tomorrow: "2F7A3A", archive: "2E5A34")
        case .pop: SwipeTints(pin: "C23818", tomorrow: "9E5608", archive: "5A5246")
        }
    }

    var title: ThemeFace {
        switch self {
        case .ink: .custom(regular: InkFontName.archivoSemiBold, semibold: InkFontName.archivoSemiBold,
                           bold: InkFontName.archivoBold, heavy: InkFontName.archivoExtraBold)
        case .library: .custom(regular: "IowanOldStyle-Roman", semibold: "IowanOldStyle-Bold",
                               bold: "IowanOldStyle-Bold", heavy: "IowanOldStyle-Bold")
        case .midnight: .custom(regular: "Charter-Roman", semibold: "Charter-Bold",
                                bold: "Charter-Bold", heavy: "Charter-Black")
        case .garden: .system(.rounded)
        case .terminal: .custom(regular: "Menlo-Regular", semibold: "Menlo-Bold", bold: "Menlo-Bold", heavy: "Menlo-Bold")
        case .pop: .custom(regular: "Futura-Medium", semibold: "Futura-Bold",
                           bold: "Futura-Bold", heavy: "Futura-CondensedExtraBold")
        }
    }

    /// Small metadata: dates, badges, counts, section headers.
    var meta: ThemeFace {
        switch self {
        case .ink: .custom(regular: InkFontName.monoRegular, semibold: InkFontName.monoSemiBold,
                           bold: InkFontName.monoSemiBold, heavy: InkFontName.monoSemiBold)
        case .library: .custom(regular: "IowanOldStyle-Italic", semibold: "IowanOldStyle-BoldItalic",
                               bold: "IowanOldStyle-BoldItalic", heavy: "IowanOldStyle-BoldItalic")
        case .midnight: .system(.monospaced)
        case .garden: .system(.rounded)
        case .terminal: .custom(regular: "Menlo-Regular", semibold: "Menlo-Bold", bold: "Menlo-Bold", heavy: "Menlo-Bold")
        case .pop: .custom(regular: "AvenirNext-Medium", semibold: "AvenirNext-Bold",
                           bold: "AvenirNext-Bold", heavy: "AvenirNext-Heavy")
        }
    }

    var card: CardShape {
        switch self {
        case .ink: CardShape()
        case .library: CardShape(cornerRadius: 3)
        case .midnight: CardShape(cornerRadius: 16, alwaysFilled: true)
        case .garden: CardShape(cornerRadius: 22, alwaysFilled: true)
        case .terminal: CardShape(cornerRadius: 0)
        case .pop: CardShape(cornerRadius: 10, borderWidth: 2, hardShadow: 4)
        }
    }
}

/// The chosen theme, persisted in UserDefaults. Views pick up changes because the Ink tokens
/// (`Color.ink`, `Font.archivo`, ...) read `current` during `body`, which Observation tracks.
@MainActor @Observable
final class ThemeManager {
    static let shared = ThemeManager()
    static let key = "theme"

    var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
            InkAppearance.install()
            applyInterfaceStyle()
        }
    }

    private static var storedTheme: AppTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init) ?? .ink
    }

    private init() {
        #if DEBUG
        if ScreenshotMode.isActive {
            current = ScreenshotMode.theme
        } else {
            current = Self.storedTheme
        }
        #else
        current = Self.storedTheme
        #endif
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeManager.shared.applyInterfaceStyle() }
        }
    }

    /// Always-dark themes pin the windows dark; the rest return to the system appearance. Screenshot
    /// mode (DEBUG) pins its theme, and light unless that theme is always dark.
    /// `preferredColorScheme(nil)` doesn't reliably undo an earlier forced scheme.
    func applyInterfaceStyle() {
        var style: UIUserInterfaceStyle = current.colorScheme == .dark ? .dark : .unspecified
        #if DEBUG
        if ScreenshotMode.isActive, style == .unspecified { style = .light }
        #endif
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
