import Foundation
import Testing
@testable import ThoughtReps

@Suite("ImageToken editing")
struct ImageTokenEditingTests {
    private let id = UUID()

    private var token: String { ImageToken.token(for: id) }

    private func insert(_ text: String, at offset: Int? = nil, id: UUID? = nil) -> (text: String, cursor: Int) {
        let index = String.Index(utf16Offset: offset ?? text.utf16.count, in: text)
        let result = ImageToken.inserting(id ?? self.id, into: text, at: index)
        return (result.text, result.text.utf16.distance(from: result.text.startIndex, to: result.cursor))
    }

    // MARK: Insert

    @Test func insertsIntoEmptyText() {
        let result = insert("")
        #expect(result.text == token + "\n\n")
        #expect(result.cursor == result.text.utf16.count)
    }

    @Test func insertsAfterTextAsItsOwnParagraph() {
        let result = insert("Hello")
        #expect(result.text == "Hello\n\n" + token + "\n\n")
    }

    @Test func insertsMidLineSplitsIntoParagraphs() {
        let result = insert("ab cd", at: 2)
        #expect(result.text == "ab\n\n" + token + "\n\n cd")
    }

    @Test func insertsAtLineStartReusingExistingBreaks() {
        let result = insert("one\n\ntwo", at: 5)
        #expect(result.text == "one\n\n" + token + "\n\ntwo")
        #expect(result.cursor == ("one\n\n" + token + "\n\n").utf16.count)
    }

    @Test func insertsAtEndOfLineAddsOnlyWhatIsMissing() {
        let result = insert("one\ntwo", at: 3)
        #expect(result.text == "one\n\n" + token + "\n\ntwo")
        #expect(result.cursor == ("one\n\n" + token + "\n\n").utf16.count)
    }

    @Test func consecutiveInsertsAreSeparateParagraphs() {
        let other = UUID()
        let first = insert("Intro")
        let second = insert(first.text, at: first.cursor, id: other)
        #expect(second.text == "Intro\n\n" + token + "\n\n" + ImageToken.token(for: other) + "\n\n")
        #expect(second.cursor == second.text.utf16.count)
    }

    @Test func insertsAfterEmojiWithTheCursorMidString() {
        let text = "a😀b🎉c"
        let offset = "a😀b".utf16.count
        let result = insert(text, at: offset)
        #expect(result.text == "a😀b\n\n" + token + "\n\n🎉c")
        #expect(result.cursor == ("a😀b\n\n" + token + "\n\n").utf16.count)
    }

    // MARK: Remove

    @Test func removesTokenAndItsEmptyLine() {
        let text = "Hello\n" + token + "\nWorld"
        #expect(ImageToken.removing(id, from: text) == "Hello\nWorld")
    }

    @Test func removingAnInsertedParagraphRestoresTheText() {
        let inserted = insert("Hello\n\nWorld", at: 7).text
        #expect(ImageToken.removing(id, from: inserted) == "Hello\n\nWorld")
    }

    @Test func removesTokenFromMixedLineKeepingText() {
        let text = "See " + token + " here"
        #expect(ImageToken.removing(id, from: text) == "See  here")
    }

    @Test func removesTokenWithAltText() {
        let text = "Top\n\n![a photo](img:\(id.uuidString))\n\nBottom"
        #expect(ImageToken.removing(id, from: text) == "Top\n\nBottom")
    }

    @Test func removesEveryCopyAndLeavesOtherImages() {
        let other = UUID()
        let text = [token, ImageToken.token(for: other), token].joined(separator: "\n")
        #expect(ImageToken.removing(id, from: text).trimmingCharacters(in: .newlines) == ImageToken.token(for: other))
    }

    @Test func removeIsCaseInsensitiveOnTheUUID() {
        let text = token.lowercased() + "\nrest"
        #expect(ImageToken.removing(id, from: text) == "rest")
    }

    @Test func leavesTokensInCodeAlone() {
        let text = "```\n\(token)\n```\n\n`\(token)`\n\n\(token)"
        let result = ImageToken.removing(id, from: text)
        #expect(result.contains("```\n\(token)\n```"))
        #expect(result.contains("`\(token)`"))
        #expect(ImageToken.references(in: result).isEmpty)
    }

    @Test func removesAfterEmojiWithoutDamagingText() {
        let text = "😀 one\n\n" + token + "\n\n🎉 two"
        #expect(ImageToken.removing(id, from: text) == "😀 one\n\n🎉 two")
    }

    @Test func removingTheOnlyTokenLeavesNothing() {
        #expect(ImageToken.removing(id, from: token + "\n\n") == "")
    }

    // MARK: References

    @Test func uniqueReferencesKeepTextOrderAndDropDuplicates() {
        let other = UUID()
        let text = [ImageToken.token(for: other), "x", token, ImageToken.token(for: other)].joined(separator: "\n")
        #expect(ImageToken.uniqueReferences(in: text) == [other, id])
    }

    @Test func altTextsComeFromTheFirstNonEmptyAlt() {
        let text = "![](img:\(id.uuidString)) ![Sunset](img:\(id.uuidString)) ![Later](img:\(id.uuidString))"
        #expect(ImageToken.altTexts(in: text) == [id: "Sunset"])
    }

    // MARK: URL resolution

    @Test func rejectsNonImageSchemes() {
        for text in ["http://example.com/a.png", "https://example.com/a.png", "file:///tmp/a.png", "img:", "img:123", "imgs:\(id.uuidString)"] {
            #expect(ImageToken.id(from: URL(string: text)!) == nil, "\(text)")
        }
    }
}
