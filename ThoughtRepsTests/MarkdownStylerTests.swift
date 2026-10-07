import Foundation
import Testing
@testable import ThoughtReps

@Suite("MarkdownStyler")
struct MarkdownStylerTests {
    typealias Run = MarkdownStyler.Run

    private func runs(_ text: String) -> [Run] { MarkdownStyler.runs(in: text) }

    /// The substrings covered by runs of `style`, in the order emitted.
    private func covered(_ text: String, _ style: MarkdownStyler.Style) -> [String] {
        let ns = text as NSString
        return runs(text).filter { $0.style == style }.map { ns.substring(with: $0.range) }
    }

    private func range(_ text: String, _ needle: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    // MARK: Blocks

    @Test func headingLevelsCoverTheLineAndFadeTheHashes() {
        for level in 1...6 {
            let text = String(repeating: "#", count: level) + " Title"
            #expect(covered(text, .heading(level: level)) == [text])
            #expect(covered(text, .syntax) == [String(repeating: "#", count: level) + " "])
        }
    }

    @Test func notAHeading() {
        #expect(covered("#hash", .heading(level: 1)).isEmpty)
        #expect(covered("####### seven", .heading(level: 6)).isEmpty)
        #expect(covered("    # indented", .heading(level: 1)).isEmpty)
    }

    @Test func blockquoteStartsAtTheMarker() {
        #expect(covered("> quoted *text*", .blockquote) == ["> quoted *text*"])
        #expect(covered("> quoted", .syntax) == ["> "])
        #expect(covered("> > nested", .syntax) == ["> ", "> "])
    }

    @Test func listMarkers() {
        #expect(covered("- item", .listMarker) == ["-"])
        #expect(covered("  * item", .listMarker) == ["*"])
        #expect(covered("12. item", .listMarker) == ["12."])
        #expect(covered("3) item", .listMarker) == ["3)"])
        #expect(covered("-no space", .listMarker).isEmpty)
        #expect(covered("*emphasis* start", .listMarker).isEmpty)
    }

    @Test func listPrefixCoversMarkerBoxAndSpaces() {
        func prefix(_ text: String) -> (String, MarkdownStyler.ListPrefix)? {
            for run in runs(text) {
                if case let .listPrefix(info) = run.style { return ((text as NSString).substring(with: run.range), info) }
            }
            return nil
        }
        #expect(prefix("- item")?.0 == "- ")
        #expect(prefix("  *   item")?.0 == "*   ")
        #expect(prefix("12. item")?.0 == "12. ")
        #expect(prefix("12. item")?.1.kind == .numbered)
        #expect(prefix("12. item")?.1.markerLength == 3)
        #expect(prefix("- [ ] todo")?.0 == "- [ ] ")
        #expect(prefix("- [x] done")?.1.kind == .task(checked: true))
        #expect(prefix("- ")?.0 == "- ")
        #expect(prefix("plain") == nil)
    }

    @Test func listLevelsFollowIndentation() {
        let text = "- a\n  - b\n    - c\n  - d\n- e\n\ntext\n- f"
        var levels: [Int] = []
        for run in runs(text) {
            if case let .listPrefix(info) = run.style { levels.append(info.level) }
        }
        #expect(levels == [1, 2, 3, 2, 1, 1])
    }

    @Test func fenceLinesGetAFenceRun() {
        let text = "a\n```\ncode\n```\nb"
        #expect(covered(text, .fence) == ["```\n", "```\n"])
    }

    // MARK: Cursor reveal

    private func reveal(_ text: String, _ selection: NSRange) -> String {
        let units = Array(text.utf16)
        let range = MarkdownStyler.revealRange(in: units, selection: selection)
        return (text as NSString).substring(with: range)
    }

    @Test func revealCoversTheCursorLine() {
        let text = "one\ntwo\nthree"
        #expect(reveal(text, NSRange(location: 5, length: 0)) == "two\n")
        #expect(reveal(text, NSRange(location: 3, length: 0)) == "one\n")
        #expect(reveal(text, NSRange(location: 4, length: 0)) == "two\n")
        #expect(reveal(text, NSRange(location: 13, length: 0)) == "three")
    }

    @Test func multiLineSelectionRevealsEveryLineItTouches() {
        let text = "one\ntwo\nthree\nfour"
        #expect(reveal(text, NSRange(location: 1, length: 8)) == "one\ntwo\nthree\n")
        #expect(reveal(text, NSRange(location: 4, length: 4)) == "two\n")
        #expect(reveal(text, NSRange(location: 4, length: 5)) == "two\nthree\n")
    }

    @Test func revealWidensToTheWholeFencedBlock() {
        let text = "a\n```\nx\ny\n```\nb"
        #expect(reveal(text, NSRange(location: 8, length: 0)) == "```\nx\ny\n```\n")
        #expect(reveal(text, NSRange(location: 2, length: 0)) == "```\nx\ny\n```\n")
        #expect(reveal("a\n```\nx", NSRange(location: 6, length: 0)) == "```\nx")
        #expect(reveal(text, NSRange(location: 0, length: 0)) == "a\n")
    }

    @Test func revealOfEmptyText() {
        #expect(MarkdownStyler.revealRange(in: [], selection: NSRange(location: 0, length: 0)) == NSRange(location: 0, length: 0))
    }

    @Test func taskMarkers() {
        #expect(covered("- [ ] todo", .taskMarker(checked: false)) == ["[ ]"])
        #expect(covered("- [x] done", .taskMarker(checked: true)) == ["[x]"])
        #expect(covered("- [X] done", .taskMarker(checked: true)) == ["[X]"])
        #expect(covered("- [] nope", .taskMarker(checked: false)).isEmpty)
    }

    @Test func thematicBreakIsFaded() {
        #expect(covered("---", .thematicBreak) == ["---"])
        #expect(covered("* * *", .thematicBreak) == ["* * *"])
        #expect(covered("---", .listMarker).isEmpty)
    }

    @Test func fencedCodeCoversWholeLines() {
        let text = "before\n```swift\nlet x = 1\n```\nafter"
        #expect(covered(text, .codeBlock) == ["```swift\n", "let x = 1\n", "```\n"])
        #expect(covered(text, .syntax) == ["```", "```"])
    }

    @Test func tildeFenceNeedsMatchingTildes() {
        let text = "~~~\ncode\n```\nstill code\n~~~"
        #expect(covered(text, .codeBlock) == ["~~~\n", "code\n", "```\n", "still code\n", "~~~"])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        let text = "```\nline 1\n\nline 3 **not bold**"
        #expect(covered(text, .codeBlock) == ["```\n", "line 1\n", "\n", "line 3 **not bold**"])
        #expect(covered(text, .bold).isEmpty)
    }

    @Test func codeBlockContentsAreNotStyledInline() {
        let text = "```\n**x** #tag [a](b)\n```"
        #expect(covered(text, .bold).isEmpty)
        #expect(covered(text, .tag).isEmpty)
        #expect(covered(text, .link).isEmpty)
    }

    @Test func fenceInsideListOrWithFourBackticksOnOneLineIsInlineCode() {
        #expect(covered("a ```code``` b", .inlineCode) == ["```code```"])
        #expect(covered("a ```code``` b", .codeBlock).isEmpty)
    }

    // MARK: Inline

    @Test func boldItalicStrikethrough() {
        #expect(covered("a **bold** b", .bold) == ["**bold**"])
        #expect(covered("a __bold__ b", .bold) == ["__bold__"])
        #expect(covered("a *it* b", .italic) == ["*it*"])
        #expect(covered("a _it_ b", .italic) == ["_it_"])
        #expect(covered("a ~~gone~~ b", .strikethrough) == ["~~gone~~"])
    }

    @Test func tripleIsBoldAndItalic() {
        #expect(covered("***both***", .bold) == ["***both***"])
        #expect(covered("***both***", .italic) == ["***both***"])
        #expect(covered("***both***", .syntax) == ["***", "***"])
    }

    @Test func nestedEmphasis() {
        let text = "**bold _and italic_ text**"
        #expect(covered(text, .bold) == [text])
        #expect(covered(text, .italic) == ["_and italic_"])
        #expect(covered("*a **b** c*", .italic) == ["*a **b** c*"])
        #expect(covered("*a **b** c*", .bold) == ["**b**"])
    }

    @Test func delimitersAreFadedNotHidden() {
        #expect(covered("**bold**", .syntax) == ["**", "**"])
        #expect(covered("_it_", .syntax) == ["_", "_"])
        #expect(covered("~~x~~", .syntax) == ["~~", "~~"])
    }

    @Test func unclosedOrSpacedMarkersStyleNothing() {
        for text in ["**unclosed", "a ** b **", "*", "__", "~~ x ~~", "snake_case_name", "2 * 3 * 4"] {
            let styled = runs(text).filter { $0.style != .syntax }
            #expect(styled.isEmpty, "\(text)")
            #expect(runs(text).filter { $0.style == .syntax }.isEmpty, "\(text)")
        }
    }

    @Test func unclosedMarkerDoesNotStealALaterPair() {
        #expect(covered("**open and *it* more", .italic) == ["*it*"])
        #expect(covered("**open and *it* more", .bold).isEmpty)
    }

    @Test func escapedMarkersAreLiteral() {
        #expect(covered(#"\*not italic\*"#, .italic).isEmpty)
        #expect(covered(#"\*not italic\*"#, .syntax) == ["\\", "\\"])
    }

    @Test func inlineCodeIncludesBackticksAndMasksInside() {
        #expect(covered("use `a **b** #c` here", .inlineCode) == ["`a **b** #c`"])
        #expect(covered("use `a **b** #c` here", .bold).isEmpty)
        #expect(covered("use `a **b** #c` here", .tag).isEmpty)
        #expect(covered("use ``a ` b`` here", .inlineCode) == ["``a ` b``"])
        #expect(covered("`unclosed", .inlineCode).isEmpty)
    }

    @Test func links() {
        let text = "see [the docs](https://example.com/x) now"
        #expect(covered(text, .link) == ["the docs"])
        #expect(covered(text, .syntax) == ["[", "](https://example.com/x)"])
        #expect(covered("<https://example.com>", .link) == ["https://example.com"])
        #expect(covered("<https://example.com>", .syntax) == ["<", ">"])
        #expect(covered("go to https://example.com/a_b_c, ok", .link) == ["https://example.com/a_b_c"])
        #expect(covered("go to https://example.com/a_b_c, ok", .italic).isEmpty)
    }

    @Test func emphasisInsideLinkText() {
        #expect(covered("[**bold** link](u)", .bold) == ["**bold**"])
    }

    @Test func urlUnderscoresAreNotItalic() {
        #expect(covered("[x](https://a.com/_a_)", .italic).isEmpty)
    }

    @Test func imageTokens() {
        let id = UUID()
        let token = ImageToken.token(for: id)
        let text = "before\n\n\(token)\n\nafter"
        #expect(runs(text).filter { $0.style == .image(id) }.map(\.range) == [range(text, token)])
        #expect(covered("`\(token)`", .image(id)).isEmpty)
        #expect(covered("```\n\(token)\n```", .image(id)).isEmpty)
    }

    @Test func imageTokenContentsAreNotLinkedOrTagged() {
        let token = ImageToken.token(for: UUID())
        #expect(covered(token, .link).isEmpty)
        #expect(covered(token, .syntax).isEmpty)
    }

    @Test func ordinaryImageIsALink() {
        #expect(covered("![alt](https://x.com/a.png)", .link) == ["alt"])
        #expect(covered("![alt](https://x.com/a.png)", .syntax) == ["![", "](https://x.com/a.png)"])
    }

    // MARK: Tags

    @Test func tagsAreTinted() {
        #expect(covered("a #Swift and #idea-2 b", .tag) == ["#Swift", "#idea-2"])
    }

    @Test func tagsFollowTagParserRules() {
        let corpus = [
            "Learned #Swift today",
            "#a1 and #b2",
            "# Title\n#tag after",
            "see example.com/#section and C#sharp",
            "trailing #swift- hyphen",
            "#1 is not a tag, #_ok is",
            "&#39; entity and #real",
            "> quoted #tag",
            "- list #item",
            "**bold #tag**",
            "#cafe\u{301} decomposed",
        ]
        for text in corpus {
            let expected = TagParser.matches(in: text).map(\.range)
            let actual = runs(text).filter { $0.style == .tag }.map(\.range)
            #expect(actual == expected, "\(text)")
        }
    }

    @Test func tagsAgreeWithTagParserAroundOddFences() {
        let corpus = [
            "    ```\n#hidden\n    ```\n#shown",
            "text ~~~ mid-line fence\n#hidden\nmore",
            "text ~~~ mid-line fence ~~~ closed\n#shown",
            "```a`b\n#hidden",
            "  ```\n#hidden\n  ```\n#shown",
            "```\n#hidden\n```\n#shown ```\n#hidden2",
        ]
        for text in corpus {
            let expected = TagParser.matches(in: text).map(\.range)
            let actual = runs(text).filter { $0.style == .tag }.map(\.range)
            #expect(actual == expected, "\(text.debugDescription)")
        }
    }

    @Test func tagsInCodeAndLinksAreLeftAlone() {
        #expect(covered("Use `#available` here", .tag).isEmpty)
        #expect(covered("[read #later](https://x.com)", .tag).isEmpty)
        #expect(covered("<https://x.com/#frag>", .tag).isEmpty)
        #expect(covered("\\#escaped", .tag).isEmpty)
        #expect(covered("[x](https://x.com) #real", .tag) == ["#real"])
    }

    // MARK: Offsets

    @Test func rangesAreUTF16UnitsAfterEmoji() {
        let text = "👩‍👩‍👧 **bold** 🎉 #tag"
        let ns = text as NSString
        let bold = runs(text).first { $0.style == .bold }
        #expect(bold.map { ns.substring(with: $0.range) } == "**bold**")
        #expect(covered(text, .tag) == ["#tag"])
    }

    @Test func rangesOnLaterLinesAreDocumentOffsets() {
        let text = "😀\n\n## Heading with *it*\n- [ ] task"
        #expect(covered(text, .italic) == ["*it*"])
        #expect(covered(text, .heading(level: 2)) == ["## Heading with *it*"])
        #expect(covered(text, .taskMarker(checked: false)) == ["[ ]"])
    }

    @Test func emptyAndWhitespaceText() {
        #expect(runs("").isEmpty)
        #expect(runs("\n\n  \n").isEmpty)
    }

    // MARK: Partial runs

    @Test func runsForARangeMatchTheFullScan() {
        let text = "# Title\n\nSome *text* here\n```\ncode **x**\n```\n- [x] done #tag\n> quote"
        let full = runs(text)
        let ns = text as NSString
        for (index, lineRange) in lineRanges(of: ns).enumerated() {
            let partial = MarkdownStyler.runs(in: text, range: lineRange)
            let expected = full.filter { NSIntersectionRange($0.range, lineRange).length > 0 || $0.range.location == lineRange.location }
            #expect(partial == expected, "line \(index)")
        }
    }

    @Test func tagsOfALaterLineKnowAboutAFenceOpenedEarlier() {
        let text = "a ~~~ x\n#hidden\nb ~~~\n#shown\n``` c\n#hidden2\n```\n#shown2"
        let ns = text as NSString
        let all = runs(text).filter { $0.style == .tag }.map(\.range)
        #expect(all == TagParser.matches(in: text).map(\.range))
        var partial: [NSRange] = []
        for line in lineRanges(of: ns) {
            partial += MarkdownStyler.runs(in: text, range: line).filter { $0.style == .tag }.map(\.range)
        }
        #expect(partial == all)
    }

    private func lineRanges(of ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            result.append(line)
            location = line.upperBound
        }
        return result
    }

    // MARK: Restyle range

    @Test func editWidensToItsLines() {
        let text = "one\ntwo words\nthree"
        let edited = range(text, "words")
        #expect(MarkdownStyler.restyleRange(in: text, edited: edited) == range(text, "two words\n"))
    }

    @Test func insertedNewlineIncludesTheNewLine() {
        let text = "ab\ncd\nef"
        #expect(MarkdownStyler.restyleRange(in: text, edited: NSRange(location: 2, length: 1)) == NSRange(location: 0, length: 6))
    }

    @Test func editAtTheEndAndOfEmptyText() {
        #expect(MarkdownStyler.restyleRange(in: "", edited: NSRange(location: 0, length: 0)) == NSRange(location: 0, length: 0))
        #expect(MarkdownStyler.restyleRange(in: "abc", edited: NSRange(location: 3, length: 0)) == NSRange(location: 0, length: 3))
        #expect(MarkdownStyler.restyleRange(in: "abc\n", edited: NSRange(location: 4, length: 0)) == NSRange(location: 4, length: 0))
    }

    @Test func rangeIsClampedToTheText() {
        #expect(MarkdownStyler.restyleRange(in: "abc", edited: NSRange(location: 1, length: 50)) == NSRange(location: 0, length: 3))
    }

    @Test func typingAFenceWidensToTheEnd() {
        let text = "intro\n```\nbody\nmore\n"
        let edited = range(text, "```")
        #expect(MarkdownStyler.restyleRange(in: text, edited: edited) == NSRange(location: 6, length: (text as NSString).length - 6))
    }

    @Test func editingAClosingFenceWidensToTheEnd() {
        let text = "```\nbody\n```\nafter\nmore"
        let closing = NSRange(location: 9, length: 3)
        #expect(MarkdownStyler.restyleRange(in: text, edited: closing) == NSRange(location: 9, length: (text as NSString).length - 9))
    }

    @Test func removingAFenceWidensWhenToldSo() {
        let text = "intro\n``\nbody\nmore"
        let edited = NSRange(location: 8, length: 0)
        #expect(MarkdownStyler.restyleRange(in: text, edited: edited) == range(text, "``\n"))
        #expect(
            MarkdownStyler.restyleRange(in: text, edited: edited, fenceChanged: true)
                == NSRange(location: 6, length: (text as NSString).length - 6)
        )
    }

    @Test func editInsideACodeBlockStaysOnItsLine() {
        let text = "```\nbody\nmore\n```\nafter"
        #expect(MarkdownStyler.restyleRange(in: text, edited: NSRange(location: 6, length: 1)) == range(text, "body\n"))
    }

    @Test func listSignatureChangesOnlyWhenTheListStructureDoes() {
        func signature(_ text: String) -> [Int] { MarkdownStyler.listSignature(of: Array(text.utf16)) }
        #expect(signature("- a") == signature("- a longer item"))
        #expect(signature("- a") != signature("  - a"))
        #expect(signature("- a") != signature("1. a"))
        #expect(signature("- a") == signature("* a"))
        #expect(signature("- a") != signature("a"))
        #expect(signature("- a") != signature("- a\n- b"))
        #expect(signature("plain text") == signature("other"))
    }

    @Test func listChangeWidensToTheEndOfTheListBlock() {
        let text = "- a\n  - b\n    - c\n\n  more\nplain\n- z"
        let edited = NSRange(location: 4, length: 1)
        let plain = MarkdownStyler.restyleRange(in: text, edited: edited)
        let widened = (text as NSString).range(of: "- a\n  - b\n    - c\n\n  more\n")
        #expect(plain == (text as NSString).range(of: "  - b\n"))
        let region = MarkdownStyler.restyleRange(in: Array(text.utf16), edited: edited, listChanged: true)
        #expect(region == NSRange(location: plain.location, length: widened.upperBound - plain.location))
    }

    @Test func fenceDetection() {
        #expect(MarkdownStyler.hasFenceMarker(Array("a\n```swift\nb".utf16)))
        #expect(MarkdownStyler.hasFenceMarker(Array("~~~".utf16)))
        #expect(!MarkdownStyler.hasFenceMarker(Array("``\nno".utf16)))
        #expect(!MarkdownStyler.hasFenceMarker(Array("`` ` ``` x".utf16)))
        #expect(!MarkdownStyler.hasFenceMarker([]))
    }

    @Test func restylingTheWidenedRangeMatchesAFullScan() {
        let before = "intro\n```\ncode **x**\n```\ntail **y**\n"
        let after = "intro\n``\ncode **x**\n```\ntail **y**\n"
        let ns = after as NSString
        let region = MarkdownStyler.restyleRange(in: after, edited: NSRange(location: 8, length: 0), fenceChanged: true)
        let partial = MarkdownStyler.runs(in: after, range: region)
        let full = MarkdownStyler.runs(in: after).filter { $0.range.location >= region.location }
        #expect(partial == full)
        #expect(covered(before, .codeBlock).count == 3)
        #expect(partial.contains { $0.style == .bold && ns.substring(with: $0.range) == "**x**" })
    }

    // MARK: Performance

    @Test func singleVeryLongLineOfUnmatchedMarkersStaysLinear() {
        let unit = "a *b _c `d [e <f ![g ~~h **i __j #k "
        let text = String(repeating: unit, count: 50_000 / unit.count + 1)
        #expect(text.utf16.count >= 50_000)
        let started = ContinuousClock.now
        _ = MarkdownStyler.runs(in: text)
        #expect(ContinuousClock.now - started < .seconds(1))

        let ticks = String(repeating: "`` ` ```", count: 8_000)
        let ticksStarted = ContinuousClock.now
        _ = MarkdownStyler.runs(in: ticks)
        #expect(ContinuousClock.now - ticksStarted < .seconds(1))
    }

    @Test func imageTokenScanStaysLinearOnALongLineOfUnmatchedImageOpeners() {
        let id = UUID().uuidString
        let unit = "![a ![b [c ](img:\(id))"
        let broken = "![a ![b ](img:not-a-uuid "
        let text = String(repeating: broken + unit + " ", count: 50_000 / (broken.count + unit.count) + 1)
        #expect(text.utf16.count >= 50_000)
        let started = ContinuousClock.now
        let found = ImageToken.matches(in: text)
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(found.count == 50_000 / (broken.count + unit.count) + 1)
        #expect(found.allSatisfy { $0.id.uuidString == id })

        let openers = String(repeating: "![x ", count: 12_500) + "](img:\(id))"
        let openersStarted = ContinuousClock.now
        let result = ImageToken.matches(in: openers)
        #expect(ContinuousClock.now - openersStarted < .milliseconds(500))
        #expect(result.count == 1)
    }

    @Test func imageTokenMatchesAgreeWithTheRegexOnOrdinaryTokens() {
        let a = UUID(), b = UUID()
        let text = "x ![](img:\(a.uuidString)) y ![alt text](img:\(b.uuidString))\n![nope](img:zzz)"
        let found = ImageToken.matches(in: text)
        #expect(found.map(\.id) == [a, b])
        #expect(found.map { (text as NSString).substring(with: $0.range) } == [
            "![](img:\(a.uuidString))", "![alt text](img:\(b.uuidString))",
        ])
    }

    @Test func largeDocumentScansQuickly() {
        let paragraph = "Some *emphasis*, **bold**, `code`, [link](https://x.com) and #tag in a line of prose.\n"
        let text = String(repeating: paragraph, count: 600)
        #expect(text.utf16.count > 50_000)
        let started = ContinuousClock.now
        let scanned = MarkdownStyler.runs(in: text)
        let elapsed = ContinuousClock.now - started
        #expect(scanned.count > 600 * 8)
        #expect(elapsed < .seconds(5))

        let units = Array(text.utf16)
        let region = MarkdownStyler.restyleRange(in: units, edited: NSRange(location: 30_000, length: 1))
        let partialStart = ContinuousClock.now
        _ = MarkdownStyler.runs(in: units, range: region)
        #expect(ContinuousClock.now - partialStart < .milliseconds(500))
    }
}
