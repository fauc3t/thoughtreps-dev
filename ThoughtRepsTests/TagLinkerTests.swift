import Foundation
import Testing
@testable import ThoughtReps

@Suite("TagLinker")
struct TagLinkerTests {
    @Test func linksPlainTag() {
        #expect(TagLinker.link("Learned #Swift today") == "Learned [#Swift](thoughtreps-tag:swift) today")
    }

    @Test func linksMultipleTags() {
        #expect(TagLinker.link("#a1 and #b2") == "[#a1](thoughtreps-tag:a1) and [#b2](thoughtreps-tag:b2)")
    }

    @Test func leavesCodeAlone() {
        #expect(TagLinker.link("Use `#available` here") == "Use `#available` here")
        #expect(TagLinker.link("```\n#nope\n```") == "```\n#nope\n```")
    }

    @Test func leavesHeadingsAndFragmentsAlone() {
        #expect(TagLinker.link("# Title") == "# Title")
        #expect(TagLinker.link("see example.com/#section") == "see example.com/#section")
    }

    @Test func leavesTagsInsideLinksAlone() {
        #expect(TagLinker.link("[read #later](https://x.com)") == "[read #later](https://x.com)")
        #expect(TagLinker.link("<https://x.com/#frag>") == "<https://x.com/#frag>")
        #expect(TagLinker.link("[x](https://x.com) #real") == "[x](https://x.com) [#real](thoughtreps-tag:real)")
    }

    @Test func prefixTagsAreDistinct() {
        #expect(TagLinker.link("#swift #swiftui") == "[#swift](thoughtreps-tag:swift) [#swiftui](thoughtreps-tag:swiftui)")
    }

    @Test func trailingHyphenStaysOutsideLink() {
        #expect(TagLinker.link("so #swift- ok") == "so [#swift](thoughtreps-tag:swift)- ok")
    }

    @Test func percentEncodesUnicode() {
        #expect(TagLinker.link("#café") == "[#café](thoughtreps-tag:caf%C3%A9)")
    }

    @Test func bodyWithoutTagsIsUnchanged() {
        let body = "Nothing **here**\n\n- item"
        #expect(TagLinker.link(body) == body)
    }

    @Test func codeBeforeTagKeepsOffsetsAligned() {
        #expect(TagLinker.link("`#a` #b") == "`#a` [#b](thoughtreps-tag:b)")
        #expect(TagLinker.link("```\n#a\n```\n#b") == "```\n#a\n```\n[#b](thoughtreps-tag:b)")
    }

    @Test func linksDecomposedInput() {
        #expect(TagLinker.link("#cafe\u{301}") == "[#café](thoughtreps-tag:caf%C3%A9)")
    }

    @Test func respectsBackslashEscapes() {
        #expect(TagLinker.link("\\#tag") == "\\#tag")
        #expect(TagLinker.link("\\\\#tag") == "\\\\[#tag](thoughtreps-tag:tag)")
    }

    @Test func linksInTablesEmphasisAndHeadings() {
        #expect(TagLinker.link("| a | #b |") == "| a | [#b](thoughtreps-tag:b) |")
        #expect(TagLinker.link("**#bold**") == "**[#bold](thoughtreps-tag:bold)**")
        #expect(TagLinker.link("## Notes #work") == "## Notes [#work](thoughtreps-tag:work)")
    }

    @Test func leavesImageAltAlone() {
        #expect(TagLinker.link("![alt #x](u)") == "![alt #x](u)")
    }

    @Test func escapesUnderscoresInLabelOnly() {
        #expect(TagLinker.link("#_foo_") == "[#\\_foo\\_](thoughtreps-tag:_foo_)")
    }

    @Test func parserMatchRanges() {
        let matches = TagParser.matches(in: "hi #swift- there")
        #expect(matches.count == 1)
        #expect(matches[0].range == NSRange(location: 3, length: 6))
        #expect(matches[0].tag.key == "swift")
    }

    @Test func keyRoundTrips() {
        #expect(TagLinker.key(from: URL(string: "thoughtreps-tag:caf%C3%A9")!) == "café")
        #expect(TagLinker.key(from: URL(string: "https://x.com")!) == nil)
    }
}
