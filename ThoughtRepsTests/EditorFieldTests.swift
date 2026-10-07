import Foundation
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Editor fields")
struct EditorFieldTests {
    @Test func changedIndexFindsTheOneEditedText() {
        #expect(EditorField.changedIndex(from: ["a", "b", "c"], to: ["a", "bb", "c"]) == 1)
        #expect(EditorField.changedIndex(from: ["a"], to: ["b"]) == 0)
    }

    @Test func changedIndexIgnoresNoChangeManyChangesAndResizedLists() {
        #expect(EditorField.changedIndex(from: ["a", "b"], to: ["a", "b"]) == nil)
        #expect(EditorField.changedIndex(from: ["a", "b"], to: ["x", "y"]) == nil)
        #expect(EditorField.changedIndex(from: ["a"], to: ["a", "b"]) == nil)
    }

    @Test func thumbnailsFollowTokenOrderAndSkipUnknownImages() {
        let first = newImage(1)
        let second = newImage(2)
        let text = "\(ImageToken.token(for: second.id))\n\n\(ImageToken.token(for: UUID()))\n\n\(ImageToken.token(for: first.id))"
        let found = inlineThumbnails(in: text, drafts: [first, second], stored: [:])
        #expect(found.map(\.id) == [second.id, first.id])
        #expect(inlineThumbnails(in: "no images", drafts: [first], stored: [:]).isEmpty)
    }

    @Test func spokenTextDropsImageTokens() {
        let text = "# Answer\n\(ImageToken.token(for: UUID()))\n\nSee **this** and [a link](https://example.com)"
        #expect(BlurredBlockView.spokenText(text) == "Answer. See this and a link")
    }
}
