import Testing
@testable import ThoughtReps

@Suite("TagParser")
struct TagParserTests {
    private func keys(_ text: String) -> [String] {
        TagParser.parse(text).map(\.key)
    }

    @Test func findsTagsAnywhereInOrder() {
        #expect(keys("Learned this today #swift and #study") == ["swift", "study"])
        #expect(keys("#first thing") == ["first"])
    }

    @Test func keysAreLowercaseAndDeduplicated() {
        let tags = TagParser.parse("#SwiftUI then #swiftui again")
        #expect(tags == [TagParser.ParsedTag(key: "swiftui", display: "SwiftUI")])
    }

    @Test func ignoresHeadingsAndNumbers() {
        #expect(keys("# Heading\n## Sub") == [])
        #expect(keys("Issue #42 is fixed") == [])
        #expect(keys("#2026goals") == ["2026goals"])
    }

    @Test func ignoresUrlFragmentsAndMidWordHashes() {
        #expect(keys("see example.com/#section") == [])
        #expect(keys("C# and F# are languages") == [])
        #expect(keys("an entity &#39; here") == [])
    }

    @Test func ignoresCode() {
        #expect(keys("Use `#available` checks #swift") == ["swift"])
        #expect(keys("```\n#notatag\n```\n#real") == ["real"])
        #expect(keys("~~~\n#notatag\n~~~\n#real") == ["real"])
        #expect(keys("~~~\n```\n#notatag\n~~~\n#real") == ["real"])
    }

    @Test func allowsHyphensUnderscoresAndUnicode() {
        #expect(keys("#side-project #to_read #café") == ["side-project", "to_read", "café"])
    }

    @Test func precomposedAndDecomposedAreOneTag() {
        let tags = TagParser.parse("#caf\u{E9} and #cafe\u{301}")
        #expect(tags.map(\.key) == ["caf\u{E9}"])
    }

    @Test func dropsTrailingHyphen() {
        #expect(keys("tagged #swift- done") == ["swift"])
    }

    @Test func punctuationEndsATag() {
        #expect(keys("(#habits), #work.") == ["habits", "work"])
    }

    @Test func detectsTagOnlyLines() {
        #expect(TagParser.isOnlyTags("#swift #study"))
        #expect(!TagParser.isOnlyTags("about #swift"))
        #expect(!TagParser.isOnlyTags(""))
    }
}
