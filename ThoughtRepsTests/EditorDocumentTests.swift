import Foundation
import Testing
@testable import ThoughtReps

@Suite("Editor document")
struct EditorDocumentTests {
    private func text(_ content: String, title: String = "", blurred: Bool = false) -> BlockDraft {
        BlockDraft(kind: .markdown, title: title, content: content, isBlurred: blurred)
    }

    private func card(_ kind: BlockKind = .gallery) -> BlockDraft { BlockDraft(kind: kind) }

    // MARK: Insert

    @Test func aBlockAfterTheBodyGoesFirstWithoutSplittingIt() {
        let later = text("later")
        var document = EditorDocument(body: "Hello world", drafts: [later])
        let gallery = card()
        let target = document.insert([gallery], after: .field(.body))
        #expect(document.body == "Hello world")
        #expect(document.drafts.map(\.id).first == gallery.id)
        #expect(target == .block(later.id))
        #expect(document.drafts.map(\.id) == [gallery.id, later.id])
    }

    @Test func aBlockAfterABlockGoesRightAfterIt() {
        let first = text("alpha\nbeta")
        let other = card(.file)
        var document = EditorDocument(body: "b", drafts: [first, other])
        let link = card(.thoughtLink)
        let target = document.insert([link], after: .field(.block(first.id)))
        #expect(document.drafts[0].content == "alpha\nbeta")
        #expect(document.drafts[1].id == link.id)
        #expect(document.drafts[3].id == other.id)
        #expect(target == .block(document.drafts[2].id))
        #expect(document.drafts[2].kind == .markdown)
        #expect(document.drafts[2].content.isEmpty)
        #expect(!document.drafts[2].isBlurred)
    }

    @Test func aBlurredBlockIsNeverSplit() {
        let hidden = text("secret answer", title: "Answer", blurred: true)
        var document = EditorDocument(body: "b", drafts: [hidden])
        let gallery = card()
        let target = document.insert([gallery], after: .field(.block(hidden.id)))
        #expect(document.drafts[0] == hidden)
        #expect(document.drafts[1].id == gallery.id)
        #expect(target == .block(document.drafts[2].id))
        #expect(!document.drafts[2].isBlurred)
        #expect(document.drafts[2].title.isEmpty)
    }

    @Test func aFollowingMarkdownBlockTakesTheFocusInsteadOfANewOne() {
        let hidden = text("secret", blurred: true)
        let following = text("next")
        var document = EditorDocument(body: "b", drafts: [hidden, following])
        let target = document.insert([card(.file)], after: .field(.block(hidden.id)))
        #expect(target == .block(following.id))
        #expect(document.drafts.count == 3)
    }

    @Test func aNewTextBlockGoesAfterTheFieldAndTakesFocus() {
        let hidden = text("secret", blurred: true)
        var document = EditorDocument(body: "b", drafts: [hidden])
        let added = text("")
        #expect(document.insert([added], after: .field(.block(hidden.id))) == .block(added.id))
        #expect(document.drafts.map(\.id) == [hidden.id, added.id])
        #expect(!document.drafts[1].isBlurred)

        var fromBody = EditorDocument(body: "Hello", drafts: [hidden])
        let second = text("")
        #expect(fromBody.insert([second], after: .field(.body)) == .block(second.id))
        #expect(fromBody.drafts.map(\.id) == [second.id, hidden.id])
        #expect(fromBody.body == "Hello")
    }

    @Test func anEmptyBodyKeepsTheFocusAndGainsNoTrailingBlock() {
        let existing = text("later")
        var document = EditorDocument(body: "", drafts: [existing])
        let gallery = card()
        #expect(document.insert([gallery], after: .field(.body)) == .body)
        #expect(document.drafts.map(\.id) == [gallery.id, existing.id])

        var blank = EditorDocument(body: "  \n", drafts: [])
        #expect(blank.insert([card(.file)], after: .field(.body)) == .body)
        #expect(blank.drafts.count == 1)

        var textBlock = EditorDocument(body: "", drafts: [])
        let added = text("")
        #expect(textBlock.insert([added], after: .field(.body)) == .block(added.id))
    }

    @Test func aSelectedCardTakesTheNewBlockRightAfterIt() {
        let first = card()
        let second = card(.file)
        let after = text("after")
        var document = EditorDocument(body: "b", drafts: [first, second, after])
        let link = card(.thoughtLink)
        let target = document.insert([link], after: .card(first.id))
        #expect(document.drafts.map(\.id).prefix(2) == [first.id, link.id])
        #expect(document.drafts.map(\.id).suffix(2) == [second.id, after.id])
        #expect(document.drafts.count == 5)
        #expect(document.drafts[2].kind == .markdown)
        #expect(target == .block(document.drafts[2].id))
    }

    @Test func insertingWithoutAnAnchorAppendsAtTheEnd() {
        let existing = card()
        var document = EditorDocument(body: "Hello", drafts: [existing])
        let target = document.insert([card(.file)], after: nil)
        #expect(document.body == "Hello")
        #expect(document.drafts.count == 3)
        #expect(document.drafts[0].id == existing.id)
        #expect(target == .block(document.drafts[2].id))
        #expect(document.drafts[2].content.isEmpty)

        var empty = EditorDocument(body: "", drafts: [])
        let block = text("")
        #expect(empty.insert([block], after: nil) == .block(block.id))
        #expect(empty.drafts.map(\.id) == [block.id])
    }

    @Test func anAnchorOnADeletedBlockAppendsAtTheEnd() {
        let existing = text("x")
        var document = EditorDocument(body: "Hello", drafts: [existing])
        document.insert([card()], after: .field(.block(UUID())))
        #expect(document.drafts.first?.id == existing.id)
        #expect(document.drafts.count == 3)
    }

    @Test func multipleFilesInsertInOrderAtTheSameSpot() {
        var document = EditorDocument(body: "Hello world", drafts: [])
        let files = (0..<3).map { _ in card(.file) }
        let target = document.insert(files, after: .field(.body))
        #expect(document.body == "Hello world")
        #expect(document.drafts.prefix(3).map(\.id) == files.map(\.id))
        #expect(document.drafts.count == 4)
        #expect(target == .block(document.drafts[3].id))
    }

    // MARK: Backspace

    @Test func backspaceAfterACardSelectsItThenRemovesItWithoutJoining() {
        let gallery = card()
        let after = text("after")
        var document = EditorDocument(body: "before", drafts: [gallery, after])
        #expect(document.backspaceAtStart(of: after.id, selectedCard: nil) == .selectCard(gallery.id))
        #expect(document.drafts.count == 2)
        let result = document.backspaceAtStart(of: after.id, selectedCard: gallery.id)
        #expect(result == .moved(.init(field: .block(after.id), offset: 0)))
        #expect(document.body == "before")
        #expect(document.drafts == [after])
    }

    @Test func selectingADifferentCardStartsOver() {
        let gallery = card()
        let after = text("after")
        var document = EditorDocument(body: "before", drafts: [gallery, after])
        #expect(document.backspaceAtStart(of: after.id, selectedCard: UUID()) == .selectCard(gallery.id))
    }

    @Test func backspaceJoinsABlockIntoTheBody() {
        let block = text("second")
        var document = EditorDocument(body: "first", drafts: [block])
        let result = document.backspaceAtStart(of: block.id, selectedCard: nil)
        #expect(result == .moved(.init(field: .body, offset: 7)))
        #expect(document.body == "first\n\nsecond")
        #expect(document.drafts.isEmpty)
    }

    @Test func backspaceJoinsABlockIntoThePreviousBlock() {
        let first = text("one")
        let second = text("two")
        let third = text("three")
        var document = EditorDocument(body: "b", drafts: [first, second, third])
        let result = document.backspaceAtStart(of: second.id, selectedCard: nil)
        #expect(result == .moved(.init(field: .block(first.id), offset: 5)))
        #expect(document.drafts.map(\.content) == ["one\n\ntwo", "three"])
    }

    @Test func twoBlurredUnlabelledBlocksJoin() {
        let first = text("one", blurred: true)
        let second = text("two", blurred: true)
        var document = EditorDocument(body: "b", drafts: [first, second])
        let result = document.backspaceAtStart(of: second.id, selectedCard: nil)
        #expect(result == .moved(.init(field: .block(first.id), offset: 5)))
        #expect(document.drafts.count == 1)
        #expect(document.drafts[0].content == "one\n\ntwo")
        #expect(document.drafts[0].isBlurred)
    }

    @Test func theJoinOffsetCountsUTF16UnitsAfterAnEmoji() {
        let second = text("tail")
        var document = EditorDocument(body: "👍👨‍👩‍👧", drafts: [second])
        let before = document.body.utf16.count
        let result = document.backspaceAtStart(of: second.id, selectedCard: nil)
        #expect(result == .moved(.init(field: .body, offset: before + 2)))
        #expect(document.body == "👍👨‍👩‍👧\n\ntail")
    }

    @Test func anImageTokenSurvivesAJoin() {
        let token = ImageToken.token(for: UUID())
        let second = text("after \(token) end")
        var document = EditorDocument(body: "before", drafts: [second])
        _ = document.backspaceAtStart(of: second.id, selectedCard: nil)
        #expect(document.body == "before\n\nafter \(token) end")
        #expect(ImageToken.uniqueReferences(in: document.body).count == 1)
    }

    @Test func joiningWithAnEmptySideAddsNoSeparator() {
        let block = text("second")
        var document = EditorDocument(body: "", drafts: [block])
        #expect(document.backspaceAtStart(of: block.id, selectedCard: nil) == .moved(.init(field: .body, offset: 0)))
        #expect(document.body == "second")
    }

    @Test func backspaceDoesNothingWhenLabelOrBlurDiffers() {
        let labeled = text("two", title: "Answer")
        var document = EditorDocument(body: "one", drafts: [labeled])
        #expect(document.backspaceAtStart(of: labeled.id, selectedCard: nil) == .none)
        #expect(document.drafts == [labeled])

        let blurred = text("two", blurred: true)
        var second = EditorDocument(body: "one", drafts: [blurred])
        #expect(second.backspaceAtStart(of: blurred.id, selectedCard: nil) == .none)
        #expect(second.body == "one")

        let labeledBefore = text("one", title: "Q")
        let plain = text("two")
        var third = EditorDocument(body: "b", drafts: [labeledBefore, plain])
        #expect(third.backspaceAtStart(of: plain.id, selectedCard: nil) == .none)
        #expect(third.drafts.count == 2)
    }

    @Test func backspaceInAnEmptyBlockJustRemovesIt() {
        let empty = text("", title: "Answer", blurred: true)
        var document = EditorDocument(body: "one", drafts: [empty])
        let result = document.backspaceAtStart(of: empty.id, selectedCard: nil)
        #expect(result == .moved(.init(field: .body, offset: 3)))
        #expect(document.body == "one")
        #expect(document.drafts.isEmpty)
    }

    @Test func backspaceIgnoresCardsAndMissingBlocks() {
        let gallery = card()
        var document = EditorDocument(body: "one", drafts: [gallery])
        #expect(document.backspaceAtStart(of: gallery.id, selectedCard: nil) == .none)
        #expect(document.backspaceAtStart(of: UUID(), selectedCard: nil) == .none)
    }
}
