import Testing
@testable import ThoughtReps

@Suite("Add block")
struct AddBlockMenuTests {
    @Test func addingABlockOfAnyKindWithoutAnAnchorAppendsItWithATextBlockBelow() {
        for kind in BlockKind.allCases where kind != .markdown {
            var document = EditorDocument(body: "b", drafts: [BlockDraft(kind: .markdown)])
            let added = BlockDraft(kind: kind)
            let target = document.insert([added], after: nil)
            #expect(document.drafts.count == 3)
            #expect(document.drafts[1].id == added.id)
            #expect(document.drafts[1].kind == kind)
            #expect(document.drafts[1].content == "")
            #expect(document.drafts[1].images.isEmpty)
            #expect(target == .block(document.drafts[2].id))
        }
    }

    @Test func aNewTextBlockIsTheOneFocused() {
        var document = EditorDocument(body: "b", drafts: [])
        let added = BlockDraft(kind: .markdown)
        #expect(document.insert([added], after: nil) == .block(added.id))
        #expect(document.drafts.map(\.id) == [added.id])
    }

    @Test func insertingNothingChangesNothing() {
        let block = BlockDraft(kind: .markdown, content: "x")
        var document = EditorDocument(body: "b", drafts: [block])
        #expect(document.insert([], after: .field(.block(block.id))) == .block(block.id))
        #expect(document.insert([], after: .card(block.id)) == .body)
        #expect(document.insert([], after: nil) == .body)
        #expect(document == EditorDocument(body: "b", drafts: [block]))
    }
}
