import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ThoughtReps

@Suite("Ink style")
struct InkStyleTests {
    @Test func bundledFontsResolve() {
        for name in InkFontName.all {
            #expect(UIFont(name: name, size: 12) != nil, "missing font \(name)")
        }
    }

    @Test func themeFontsResolve() {
        for theme in AppTheme.allCases {
            for face in [theme.title, theme.meta] {
                for weight in [ThemeFace.Weight.regular, .semibold, .bold, .heavy] {
                    guard let name = face.customName(weight) else { continue }
                    if UIFont(name: name, size: 12) == nil { Issue.record("\(theme.name): missing font \(name)") }
                }
            }
        }
    }

    @Test func everyThemeDefinesAllTokens() {
        for theme in AppTheme.allCases {
            _ = (theme.palette, theme.title, theme.meta, theme.card, theme.swipe)
            #expect(!theme.name.isEmpty)
        }
    }

    private static func luminance(_ color: Color) -> Double {
        let c = components(UIColor(color), UITraitCollection(userInterfaceStyle: .light))
        let lin = c.prefix(3).map { Double($0) <= 0.03928 ? Double($0) / 12.92 : pow((Double($0) + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    @Test func swipeTintsContrastWithWhiteLabels() {
        for theme in AppTheme.allCases where theme != .ink {
            let tints = theme.swipe
            for (name, tint) in [("pin", tints.pin), ("tomorrow", tints.tomorrow), ("archive", tints.archive)] {
                let ratio = 1.05 / (Self.luminance(tint) + 0.05)
                #expect(ratio >= 4.5, "\(theme.name) \(name) contrast \(ratio)")
            }
        }
    }

    @Test func colorsResolve() {
        for name in ["Paper", "Soft", "Ink", "Muted", "Hl"] {
            #expect(UIColor(named: name) != nil, "missing color \(name)")
        }
    }

    private static func components(_ color: UIColor, _ traits: UITraitCollection) -> [CGFloat] {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    @Test func inkThemeMatchesTheAssetCatalog() {
        let palette = AppTheme.ink.palette
        let tokens: [(String, Color)] = [
            ("Paper", palette.paper), ("Soft", palette.soft), ("Ink", palette.ink),
            ("Muted", palette.muted), ("Hl", palette.hl), ("AccentColor", palette.accent),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for (name, color) in tokens {
                guard let asset = UIColor(named: name, in: .main, compatibleWith: traits) else {
                    Issue.record("missing color \(name)")
                    continue
                }
                let a = Self.components(asset, traits)
                let b = Self.components(UIColor(color), traits)
                for (x, y) in zip(a, b) {
                    #expect(abs(x - y) < 0.01, "\(name) differs in \(style == .dark ? "dark" : "light")")
                }
            }
        }
    }

    @Test func splitsPlainFirstLine() {
        let parts = ThoughtTitleSplit.split("\n# Hello *world*\n\nBody #tag\nmore")
        #expect(parts == .init(title: "Hello world", rest: "\nBody #tag\nmore"))
    }

    @Test func singleLineLeavesEmptyRest() {
        #expect(ThoughtTitleSplit.split("Just a title") == .init(title: "Just a title", rest: ""))
    }

    @Test func leavesStructuralFirstLinesWhole() {
        for body in ["- item\n- two", "1. one\n2. two", "```\ncode\n```", "![](img:x)", "> quote", "| a | b |", "   "] {
            #expect(ThoughtTitleSplit.split(body) == nil, "\(body)")
        }
    }
}
