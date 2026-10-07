import Testing
@testable import ThoughtReps

@Suite("Add block")
struct AddBlockMenuTests {
    @Test func addingABlockAppendsADraftOfThatKindAndReturnsItsId() {
        for kind in BlockKind.allCases {
            var drafts = [BlockDraft(kind: .markdown)]
            let id = drafts.addBlock(kind)
            #expect(drafts.count == 2)
            #expect(drafts.last?.kind == kind)
            #expect(drafts.last?.id == id)
            #expect(drafts.last?.content == "")
            #expect(drafts.last?.images.isEmpty == true)
        }
    }

    @Test func eachAddedBlockGetsItsOwnId() {
        var drafts: [BlockDraft] = []
        let first = drafts.addBlock(.markdown)
        let second = drafts.addBlock(.markdown)
        #expect(first != second)
        #expect(drafts.map(\.id) == [first, second])
    }
}
