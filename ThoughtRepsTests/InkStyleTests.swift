import Foundation
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

    @Test func colorsResolve() {
        for name in ["Paper", "Soft", "Ink", "Muted", "Hl"] {
            #expect(UIColor(named: name) != nil, "missing color \(name)")
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
