import Foundation
import Testing
@testable import ThoughtReps

@Suite("Conflict copy ids")
struct ConflictCopyTests {
    let original = UUID()

    func content(_ body: String, inline: UUID? = nil, gallery: UUID? = nil) -> ThoughtContentRecord {
        let text = inline.map { "\(body)\n\(ImageToken.token(for: $0))" } ?? body
        let blocks = gallery.map {
            [BlockRecord(id: UUID(), kindRaw: "gallery", title: nil, content: "", order: 0, images: [ImageRecord(id: $0, width: 4, height: 3, order: 0)])]
        } ?? []
        return ThoughtContentRecord(
            id: original, body: text, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), blocks: blocks,
            images: inline.map { [ImageRecord(id: $0, width: 4, height: 3, order: 0)] } ?? []
        )
    }

    @Test func keepingAssetsStripsALostTokenAndDropsOnlyLinesLeftEmpty() {
        let lost = UUID(), kept = UUID()
        let body = "before \(ImageToken.token(for: lost)) after\n\(ImageToken.token(for: lost))\n  \(ImageToken.token(for: kept)) tail\nlast"
        var source = content(body)
        source.images = [lost, kept].map { ImageRecord(id: $0, width: 4, height: 3, order: 0) }
        let result = ConflictCopy.keepingAssets(of: source, imageIDs: [kept], fileIDs: [])
        #expect(result.body == "before  after\n  \(ImageToken.token(for: kept)) tail\nlast")
        #expect(result.images.map(\.id) == [kept])
    }

    @Test func theCopyIdDependsOnlyOnTheOriginalAndTheLosingContent() {
        let a = content("a")
        #expect(ConflictCopy.copyID(of: original, losing: a) == ConflictCopy.copyID(of: original, losing: a))
        #expect(ConflictCopy.copyID(of: original, losing: a) != ConflictCopy.copyID(of: original, losing: content("b")))
        #expect(ConflictCopy.copyID(of: original, losing: a) != ConflictCopy.copyID(of: UUID(), losing: a))
    }

    @Test func aCopyHasNewIdsEverywhereAndItsTokensFollow() {
        let inline = UUID(), gallery = UUID()
        let source = content("text", inline: inline, gallery: gallery)
        let copyID = ConflictCopy.copyID(of: original, losing: source)
        let copy = ConflictCopy.content(source, as: copyID)
        #expect(copy.id == copyID)
        #expect(copy.images.map(\.id) == [ConflictCopy.derivedID(parent: copyID, source: inline)])
        #expect(copy.body == "text\n\(ImageToken.token(for: copy.images[0].id))")
        #expect(copy.blocks[0].id != source.blocks[0].id)
        #expect(copy.blocks[0].images[0].id == ConflictCopy.derivedID(parent: copyID, source: gallery))
        #expect(ConflictCopy.content(source, as: copyID) == copy, "the same on every device")
        #expect(copy.createdAt == source.createdAt && copy.updatedAt == source.updatedAt)
    }
}
