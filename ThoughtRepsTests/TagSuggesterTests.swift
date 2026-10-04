import Testing
@testable import ThoughtReps

@Suite("TagSuggester")
struct TagSuggesterTests {
    /// Token at a cursor given as a UTF-16 offset (defaults to the end of the text).
    private func token(_ text: String, cursor: Int? = nil) -> (range: Range<String.Index>, partial: String)? {
        let offset = cursor ?? text.utf16.count
        return TagSuggester.activeToken(in: text, cursor: String.Index(utf16Offset: offset, in: text))
    }

    private func partial(_ text: String, cursor: Int? = nil) -> String? {
        token(text, cursor: cursor)?.partial
    }

    private func candidate(_ display: String, _ count: Int) -> TagSuggester.Candidate {
        .init(key: display.lowercased(), display: display, count: count)
    }

    private func displays(_ partial: String, _ candidates: [TagSuggester.Candidate], excluding: Set<String> = [], limit: Int = 10) -> [String] {
        TagSuggester.suggestions(for: partial, from: candidates, excluding: excluding, limit: limit).map(\.display)
    }

    // MARK: Token detection

    @Test func findsTokenAtStartAndMidText() {
        #expect(partial("#sw") == "sw")
        #expect(partial("Learned #swi") == "swi")
        #expect(partial("Learned #sw today", cursor: 11) == "sw")
    }

    @Test func tokenRangeCoversHashAndPartial() throws {
        let text = "a #sw"
        let found = try #require(token(text))
        #expect(text[found.range] == "#sw")
    }

    @Test func findsTokenAfterPunctuationAndNewline() {
        #expect(partial("done (#sw") == "sw")
        #expect(partial("line one\n#sw") == "sw")
        #expect(partial("a, #sw") == "sw")
    }

    @Test func bareHashHasEmptyPartial() {
        #expect(partial("note #") == "")
        #expect(partial("#") == "")
    }

    @Test func allowsTagCharacters() {
        #expect(partial("#my-tag_2") == "my-tag_2")
        #expect(partial("#2026go") == "2026go")
        #expect(partial("#cafe\u{301}") == "cafe\u{301}")
    }

    @Test func noTokenAfterWordCharacterOrUrlOrEntity() {
        #expect(token("C#") == nil)
        #expect(token("word#sw") == nil)
        #expect(token("example.com/#sec") == nil)
        #expect(token("an entity &#39") == nil)
        #expect(token("##sw") == nil)
    }

    @Test func noTokenForHeading() {
        #expect(token("# ") == nil)
        #expect(token("# Title") == nil)
    }

    @Test func noTokenWhenPartialStartsWithHyphen() {
        #expect(token("#-") == nil)
    }

    @Test func noTokenWhenCursorIsInsideTag() {
        #expect(token("#swift", cursor: 3) == nil)
        #expect(token("#swift", cursor: 6) != nil)
    }

    @Test func noTokenInsideCode() {
        #expect(token("use `#sw") != nil)
        #expect(token("use `#sw` here", cursor: 8) == nil)
        #expect(token("```\n#sw") == nil)
        #expect(token("```\ncode\n```\n#sw")?.partial == "sw")
        #expect(token("~~~\n#sw\n~~~", cursor: 7) == nil)
    }

    @Test func tokenAfterEmojiAndMultibyteText() throws {
        let text = "caf\u{E9} \u{1F468}\u{200D}\u{1F469} #sw"
        let found = try #require(token(text))
        #expect(found.partial == "sw")
        #expect(text[found.range] == "#sw")
    }

    @Test func agreesWithParserOnWhatIsATag() {
        let samples = [
            "a #sw", "C#", "x/#y", "&#39", "#a-b", "#_x", "(#t", "#\u{24B6}x", "#a\u{200D}",
            "#cafe\u{301}", "caf\u{E9}\u{301}#x", "`#x", "`#x` #y", "```\n#x", "```\n#x\n```\n#y",
        ]
        for text in samples {
            guard let found = token(text) else { continue }
            let parsed = TagParser.parse(text).map(\.display)
            #expect(parsed.contains(found.partial), "\(text)")
        }
        #expect(token("#\u{24B6}x") == nil)
        #expect(partial("#a\u{200D}") == nil)
        #expect(partial("#cafe\u{301}") == "cafe\u{301}")
        #expect(partial("`#x` #y") == "y")
        #expect(token("```\n#x") == nil)
    }

    @Test func staleCursorIsHandled() {
        let text = "ab"
        let stale = String.Index(utf16Offset: 10, in: "0123456789abcdef")
        #expect(TagSuggester.activeToken(in: text, cursor: stale) == nil)
        #expect(TagSuggester.insertHash(in: text, at: stale).text == "ab #")
    }

    @Test func stripCodePreservesUtf16Length() {
        let texts = ["`\u{1F600}` #a", "```\n\u{1F468}\u{200D}\u{1F469}\n```\n#a", "x `a\u{E9}` ```y```"]
        for text in texts {
            #expect(TagParser.stripCode(text).utf16.count == text.utf16.count, "\(text)")
        }
    }

    @Test func parseIgnoresCodeAdjacentToTags() {
        #expect(TagParser.parse("`x`#tag").map(\.key) == ["tag"])
        #expect(TagParser.parse("```\n#no\n```\n#tag").map(\.key) == ["tag"])
    }

    // MARK: Suggestions

    @Test func prefixMatchesBeforeSubstringMatches() {
        let all = [candidate("Unswift", 50), candidate("Swift", 1), candidate("SwiftUI", 5)]
        #expect(displays("sw", all) == ["SwiftUI", "Swift", "Unswift"])
    }

    @Test func ranksByCountThenAlphabetical() {
        let all = [candidate("beta", 2), candidate("alpha", 2), candidate("gamma", 9)]
        #expect(displays("", all) == ["gamma", "alpha", "beta"])
    }

    @Test func emptyPartialListsMostUsed() {
        let all = [candidate("a", 1), candidate("b", 3), candidate("c", 2)]
        #expect(displays("", all, limit: 2) == ["b", "c"])
    }

    @Test func ignoresCaseAndDiacritics() {
        let all = [candidate("Caf\u{E9}", 3), candidate("Other", 1)]
        #expect(displays("cafe", all) == ["Caf\u{E9}"])
        #expect(displays("CAF\u{C9}", all) == ["Caf\u{E9}"])
    }

    @Test func excludesKeysAlreadyUsed() {
        let all = [candidate("swift", 3), candidate("study", 2)]
        #expect(displays("s", all, excluding: ["swift"]) == ["study"])
    }

    @Test func exactMatchIsStillSuggested() {
        #expect(displays("swift", [candidate("swift", 1)]) == ["swift"])
    }

    @Test func respectsLimitAndNoMatches() {
        let all = (0..<20).map { candidate("tag\($0)", $0) }
        #expect(displays("tag", all).count == 10)
        #expect(displays("zzz", all).isEmpty)
    }

    // MARK: Apply

    @Test func applyInsertsDisplayAndSpace() throws {
        let text = "note #sw"
        let found = try #require(token(text))
        let result = TagSuggester.apply(candidate("SwiftUI", 1), replacing: found.range, in: text)
        #expect(result.text == "note #SwiftUI ")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test func applyReusesExistingWhitespace() throws {
        let text = "note #sw more"
        let found = try #require(token(text, cursor: 8))
        let result = TagSuggester.apply(candidate("swift", 1), replacing: found.range, in: text)
        #expect(result.text == "note #swift more")
        #expect(result.text[result.cursor...] == "more")
    }

    @Test func applyBeforeNewlineKeepsIt() throws {
        let text = "#sw\nnext"
        let found = try #require(token(text, cursor: 3))
        let result = TagSuggester.apply(candidate("swift", 1), replacing: found.range, in: text)
        #expect(result.text == "#swift\nnext")
        #expect(result.text[result.cursor...] == "next")
    }

    @Test func applyInsertsSpaceBeforePunctuation() throws {
        let text = "(#sw)"
        let found = try #require(token(text, cursor: 4))
        let result = TagSuggester.apply(candidate("swift", 1), replacing: found.range, in: text)
        #expect(result.text == "(#swift )")
        #expect(result.text[result.cursor...] == ")")
    }

    @Test func applyAfterMultibyteText() throws {
        let text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} caf\u{E9} #sw"
        let found = try #require(token(text))
        let result = TagSuggester.apply(candidate("swift", 1), replacing: found.range, in: text)
        #expect(result.text == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} caf\u{E9} #swift ")
        #expect(result.cursor == result.text.endIndex)
    }

    // MARK: Insert hash

    @Test func insertHashAddsSpaceAfterWord() {
        let text = "hello"
        let result = TagSuggester.insertHash(in: text, at: text.endIndex)
        #expect(result.text == "hello #")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test func insertHashSkipsSpaceAtStartOrAfterWhitespace() {
        #expect(TagSuggester.insertHash(in: "", at: "".endIndex).text == "#")
        let text = "a \nb"
        let cursor = text.index(text.startIndex, offsetBy: 3)
        #expect(TagSuggester.insertHash(in: text, at: cursor).text == "a \n#b")
    }

    @Test func insertHashMidTextPlacesCursorAfterHash() {
        let text = "ab cd"
        let cursor = text.index(text.startIndex, offsetBy: 2)
        let result = TagSuggester.insertHash(in: text, at: cursor)
        #expect(result.text == "ab # cd")
        #expect(result.text[result.cursor...] == " cd")
    }
}
