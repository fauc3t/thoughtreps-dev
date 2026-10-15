import Foundation
import Testing
@testable import ThoughtReps

@Suite("ContentMerge")
struct ContentMergeTests {
    static let thoughtID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
    }

    static func md(_ n: Int, _ content: String, blurred: Bool = false, title: String? = nil) -> BlockRecord {
        BlockRecord(id: id(n), kindRaw: "markdown", title: title, content: content, order: 0, isBlurred: blurred, images: [])
    }

    static func gallery(_ n: Int, _ images: [Int], title: String? = nil) -> BlockRecord {
        BlockRecord(id: id(n), kindRaw: "gallery", title: title, content: "", order: 0, images: images.map(image))
    }

    static func link(_ n: Int, to target: Int) -> BlockRecord {
        BlockRecord(id: id(n), kindRaw: "thoughtLink", title: nil, content: "", order: 0, images: [], linkedThoughtID: id(target))
    }

    static func file(_ n: Int, file fileN: Int, name: String = "a.txt") -> BlockRecord {
        BlockRecord(
            id: id(n), kindRaw: "file", title: nil, content: "", order: 0, images: [],
            file: FileRecord(id: id(fileN), filename: name, typeIdentifier: "public.plain-text", byteCount: 3)
        )
    }

    static func image(_ n: Int) -> ImageRecord {
        ImageRecord(id: id(n), width: 40, height: 30, order: 0)
    }

    static func token(_ n: Int) -> String { ImageToken.token(for: id(n)) }

    static func content(
        _ body: String, blocks: [BlockRecord] = [], images: [Int] = [], updated: Double = 0
    ) -> ThoughtContentRecord {
        ThoughtContentRecord(
            id: thoughtID, body: body, createdAt: t0, updatedAt: t0.addingTimeInterval(updated),
            blocks: blocks.enumerated().map { index, block in
                var numbered = block
                numbered.order = index
                numbered.images = block.images.enumerated().map { position, image in
                    var numbered = image
                    numbered.order = position
                    return numbered
                }
                return numbered
            },
            images: images.map(image)
        )
    }

    static func merged(
        _ base: ThoughtContentRecord, _ local: ThoughtContentRecord, _ remote: ThoughtContentRecord
    ) -> ThoughtContentRecord? {
        if case .merged(let record) = ContentMerge.merge(base: base, local: local, remote: remote) { return record }
        return nil
    }

    static func lines(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    static func text(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    // MARK: Text

    @Test func editsToDifferentLinesOfOneBlockBothLand() throws {
        let base = Self.lines("l", 8)
        var mine = base
        mine[1] = "mine"
        var theirs = base
        theirs[6] = "theirs"
        let result = try #require(Self.merged(Self.content(Self.text(base)), Self.content(Self.text(mine)), Self.content(Self.text(theirs))))
        var expected = base
        expected[1] = "mine"
        expected[6] = "theirs"
        #expect(result.body == Self.text(expected))
    }

    @Test func adjacentEditsAreNotAnOverlap() throws {
        let base = Self.lines("l", 4)
        var mine = base
        mine[1] = "mine"
        var theirs = base
        theirs[2] = "theirs"
        let result = try #require(Self.merged(Self.content(Self.text(base)), Self.content(Self.text(mine)), Self.content(Self.text(theirs))))
        #expect(result.body == "l0\nmine\ntheirs\nl3")
    }

    @Test func insertionsAtDifferentPlacesAndAnInsertionNextToAnEdit() throws {
        let base = ["a", "b", "c", "d"]
        let mine = ["x", "a", "b", "c", "d"]
        let theirs = ["a", "b", "c", "d", "y"]
        #expect(Self.merged(Self.content(Self.text(base)), Self.content(Self.text(mine)), Self.content(Self.text(theirs)))?.body == "x\na\nb\nc\nd\ny")
        let insertedBeforeEdit = ["a", "n", "b", "c", "d"]
        let edited = ["a", "B", "c", "d"]
        #expect(Self.merged(Self.content(Self.text(base)), Self.content(Self.text(insertedBeforeEdit)), Self.content(Self.text(edited)))?.body == "a\nn\nB\nc\nd")
    }

    @Test func aRewriteThatAlreadyHoldsTheOthersChangeAgreesWithIt() throws {
        let base = Self.content("a\nb\nc\nd")
        let both = Self.content("a\nB\nC\nd")
        let theirs = Self.content("a\nb\nC\nd")
        #expect(Self.merged(base, both, theirs)?.body == "a\nB\nC\nd")
        #expect(Self.merged(base, theirs, both)?.body == "a\nB\nC\nd")
        #expect(ContentMerge.merge(base: base, local: both, remote: Self.content("a\nb\nX\nd")) == .conflict)
    }

    @Test func identicalChangesOnBothSidesAreFine() throws {
        let base = Self.lines("l", 5)
        var same = base
        same[2] = "same"
        var mine = same
        mine[0] = "mine"
        var theirs = same
        theirs[4] = "theirs"
        let result = try #require(Self.merged(Self.content(Self.text(base)), Self.content(Self.text(mine)), Self.content(Self.text(theirs))))
        #expect(result.body == "mine\nl1\nsame\nl3\ntheirs")
    }

    @Test func bothEditingTheSameLineIsAConflictAndAnEditAgainstADeletionToo() {
        let base = Self.content("a\nb\nc")
        #expect(ContentMerge.merge(base: base, local: Self.content("a\nX\nc"), remote: Self.content("a\nY\nc")) == .conflict)
        #expect(ContentMerge.merge(base: base, local: Self.content("a\nX\nc"), remote: Self.content("a\nc")) == .conflict)
        #expect(ContentMerge.merge(base: base, local: Self.content("a\nn1\nb\nc"), remote: Self.content("a\nn2\nb\nc")) == .conflict)
        #expect(ContentMerge.merge(base: base, local: Self.content("x\ny\nz"), remote: Self.content("a\nQ\nc")) == .conflict)
    }

    // MARK: Blocks

    @Test func editsInDifferentBlocksBothLand() throws {
        let base = Self.content("body", blocks: [Self.md(1, "one\ntwo"), Self.md(2, "three\nfour")])
        let mine = Self.content("body", blocks: [Self.md(1, "ONE\ntwo"), Self.md(2, "three\nfour")])
        let theirs = Self.content("body", blocks: [Self.md(1, "one\ntwo"), Self.md(2, "three\nFOUR")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.content) == ["ONE\ntwo", "three\nFOUR"])
        #expect(result.blocks.map(\.order) == [0, 1])
    }

    @Test func blocksAddedOnEitherSideAreKeptAfterTheirNearestPrecedingBlock() throws {
        let base = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two")])
        let mine = Self.content("b", blocks: [Self.md(1, "one"), Self.md(3, "mine"), Self.md(2, "two")])
        let theirs = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two"), Self.md(4, "theirs")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.id) == [Self.id(1), Self.id(3), Self.id(2), Self.id(4)])
    }

    @Test func aBlockRemovedOnOneSideAndUntouchedOnTheOtherIsRemoved() throws {
        let base = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two"), Self.md(3, "three")])
        let mine = Self.content("b", blocks: [Self.md(1, "one"), Self.md(3, "three")])
        let theirs = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two"), Self.md(3, "THREE")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.content) == ["one", "THREE"])
        let both = try #require(Self.merged(base, mine, mine))
        #expect(both.blocks.map(\.id) == [Self.id(1), Self.id(3)])
    }

    @Test func aBlockRemovedOnOneSideAndEditedOnTheOtherIsAConflict() {
        let base = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two")])
        let removed = Self.content("b", blocks: [Self.md(1, "one")])
        let edited = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "TWO")])
        #expect(ContentMerge.merge(base: base, local: removed, remote: edited) == .conflict)
        #expect(ContentMerge.merge(base: base, local: edited, remote: removed) == .conflict)
    }

    @Test func aReorderOnOneSideIsTaken() throws {
        let base = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two"), Self.md(3, "three")])
        let reordered = Self.content("b", blocks: [Self.md(3, "three"), Self.md(1, "one"), Self.md(2, "two")])
        let edited = Self.content("b", blocks: [Self.md(1, "one!"), Self.md(2, "two"), Self.md(3, "three")])
        let local = try #require(Self.merged(base, reordered, edited))
        #expect(local.blocks.map(\.id) == [Self.id(3), Self.id(1), Self.id(2)])
        #expect(local.blocks.map(\.content) == ["three", "one!", "two"])
        let remote = try #require(Self.merged(base, edited, reordered))
        #expect(remote.blocks.map(\.id) == [Self.id(3), Self.id(1), Self.id(2)])
    }

    @Test func whenBothReorderTheRemoteOrderWinsAndLocalAdditionsFollowTheirAnchor() throws {
        let base = Self.content("b", blocks: [Self.md(1, "one"), Self.md(2, "two"), Self.md(3, "three")])
        let mine = Self.content("b", blocks: [Self.md(2, "two"), Self.md(9, "mine"), Self.md(1, "one"), Self.md(3, "three")])
        let theirs = Self.content("b", blocks: [Self.md(3, "three"), Self.md(2, "two"), Self.md(1, "one")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.id) == [Self.id(3), Self.id(2), Self.id(9), Self.id(1)])
    }

    @Test func attributesFollowTheSideThatChangedThem() throws {
        let base = Self.content("b", blocks: [Self.md(1, "one", title: "T"), Self.md(2, "two")])
        let mine = Self.content("b", blocks: [Self.md(1, "one", blurred: true, title: "T"), Self.md(2, "two")])
        let theirs = Self.content("b", blocks: [Self.md(1, "one", title: "New"), Self.md(2, "two")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks[0].isBlurred && result.blocks[0].title == "New")
        let clash = Self.content("b", blocks: [Self.md(1, "one", title: "Other"), Self.md(2, "two")])
        #expect(ContentMerge.merge(base: base, local: clash, remote: theirs) == .conflict)
        let blurClash = Self.content("b", blocks: [Self.md(1, "one", blurred: true, title: "T"), Self.md(2, "two")])
        let unblurred = Self.content("b", blocks: [Self.md(1, "one", blurred: false, title: "T"), Self.md(2, "TWO")])
        #expect(Self.merged(base, blurClash, unblurred)?.blocks.map(\.isBlurred) == [true, false])
    }

    @Test func linkAndFileBlocksMergeAsWholeBlocks() throws {
        let base = Self.content("b", blocks: [Self.link(1, to: 50), Self.file(2, file: 60)])
        let mine = Self.content("b", blocks: [Self.link(1, to: 50), Self.file(2, file: 60), Self.link(3, to: 51)])
        let theirs = Self.content("b", blocks: [Self.link(1, to: 50), Self.file(2, file: 60), Self.file(4, file: 61, name: "b.txt")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.id) == [Self.id(1), Self.id(2), Self.id(3), Self.id(4)])

        let retargeted = Self.content("b", blocks: [Self.link(1, to: 52), Self.file(2, file: 60)])
        #expect(Self.merged(base, retargeted, theirs)?.blocks.first?.linkedThoughtID == Self.id(52))
        let other = Self.content("b", blocks: [Self.link(1, to: 53), Self.file(2, file: 60)])
        #expect(ContentMerge.merge(base: base, local: retargeted, remote: other) == .conflict)
    }

    @Test func twoLinksToTheSameTargetAddedOnBothSidesKeepOne() throws {
        let base = Self.content("b")
        let mine = Self.content("b", blocks: [Self.link(1, to: 50)])
        let theirs = Self.content("b", blocks: [Self.link(2, to: 50)])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.count == 1)
    }

    // MARK: Galleries

    @Test func galleryImagesMergeAsASetWithTheRemoteOrderWinning() throws {
        let base = Self.content("b", blocks: [Self.gallery(1, [10, 11, 12])])
        let mine = Self.content("b", blocks: [Self.gallery(1, [10, 12, 13])])
        let theirs = Self.content("b", blocks: [Self.gallery(1, [12, 11, 10, 14])])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks[0].images.map(\.id) == [Self.id(12), Self.id(10), Self.id(14), Self.id(13)])
        #expect(result.blocks[0].images.map(\.order) == [0, 1, 2, 3])
    }

    @Test func aGalleryEmptiedOnBothSidesGoesAway() throws {
        let base = Self.content("b", blocks: [Self.gallery(1, [10, 11]), Self.md(2, "two")])
        let mine = Self.content("b", blocks: [Self.gallery(1, [11]), Self.md(2, "two")])
        let theirs = Self.content("b", blocks: [Self.gallery(1, [10]), Self.md(2, "TWO")])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.blocks.map(\.id) == [Self.id(2)])
    }

    @Test func aGalleryRemovedAgainstOneEditedIsAConflict() {
        let base = Self.content("b", blocks: [Self.gallery(1, [10])])
        let removed = Self.content("b")
        let grown = Self.content("b", blocks: [Self.gallery(1, [10, 11])])
        #expect(ContentMerge.merge(base: base, local: removed, remote: grown) == .conflict)
    }

    // MARK: Images

    @Test func inlineImagesFollowTheTokensOfTheMergedText() throws {
        let base = Self.content("one\ntwo\n\(Self.token(1))\nthree", images: [1])
        let mine = Self.content("ONE\ntwo\n\(Self.token(1))\nthree\n\(Self.token(2))", images: [1, 2])
        let theirs = Self.content("\(Self.token(3))\none\ntwo\nthree", images: [3])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(result.body == "\(Self.token(3))\nONE\ntwo\nthree\n\(Self.token(2))")
        #expect(!result.body.contains(Self.token(1)), "removed on one side")
        #expect(Set(result.images.map(\.id)) == [Self.id(2), Self.id(3)])
    }

    @Test func aTokenBothSidesMovedToDifferentPlacesAppearsOnce() throws {
        let base = Self.content("a\nb\nc\nd\ne\n\(Self.token(1))", images: [1])
        let mine = Self.content("a\n\(Self.token(1))\nb\nc\nd\ne", images: [1])
        let theirs = Self.content("a\nb\nc\nd\n\(Self.token(1))\ne", images: [1])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(ImageToken.references(in: result.body) == [Self.id(1)])
        #expect(result.images.map(\.id) == [Self.id(1)])
    }

    @Test func tokensInMarkdownBlocksCountToo() throws {
        let base = Self.content("body", blocks: [Self.md(1, "x\n\(Self.token(1))")], images: [1])
        let mine = Self.content("body\n\(Self.token(2))", blocks: [Self.md(1, "x\n\(Self.token(1))")], images: [1, 2])
        let theirs = Self.content("body", blocks: [Self.md(1, "x")], images: [])
        let result = try #require(Self.merged(base, mine, theirs))
        #expect(Set(result.images.map(\.id)) == [Self.id(2)])
        #expect(result.blocks.map(\.content) == ["x"])
    }

    // MARK: Unchanged sides

    @Test func anUnchangedSideReturnsTheOtherExactly() {
        let base = Self.content("a\nb", blocks: [Self.md(1, "one")], updated: 0)
        let changed = Self.content("a\nB", blocks: [Self.md(1, "one"), Self.gallery(2, [10])], updated: 50)
        #expect(ContentMerge.merge(base: base, local: base, remote: changed) == .merged(changed))
        #expect(ContentMerge.merge(base: base, local: changed, remote: base) == .merged(changed))
        var touched = base
        touched.updatedAt = Self.t0.addingTimeInterval(99)
        #expect(ContentMerge.merge(base: base, local: touched, remote: changed) == .merged(changed), "only the clock moved")
    }

    @Test func theResolverMapsTrivialCasesToTheOldOutcomesAndConflictsToCopies() {
        let base = Self.content("a\nb\nc", updated: 0)
        let mine = Self.content("a\nmine\nc", updated: 10)
        let theirs = Self.content("a\nb\nc\nd", updated: 20)
        #expect(ContentResolver.resolve(base: base, local: base, remote: theirs) == .takeRemote)
        #expect(ContentResolver.resolve(base: base, local: mine, remote: base) == .keepLocal)
        if case .merged(let result) = ContentResolver.resolve(base: base, local: mine, remote: theirs) {
            #expect(result.body == "a\nmine\nc\nd")
        } else {
            Issue.record("expected a merge")
        }
        let clash = Self.content("a\nclash\nc", updated: 30)
        #expect(ContentResolver.resolve(base: base, local: mine, remote: clash) == .conflictCopy(winner: .remote, loser: .local))
        #expect(ContentResolver.resolve(base: base, local: clash, remote: mine) == .conflictCopy(winner: .local, loser: .remote))
    }

    // MARK: Properties

    private struct Generated {
        var base: ThoughtContentRecord
        var local: ThoughtContentRecord
        var remote: ThoughtContentRecord
        var counter = 1000
    }

    /// Unique line texts, so "added" and "removed" are well defined.
    private static func editedText(_ lines: [String], _ counter: inout Int, _ rng: inout SeededGenerator) -> [String] {
        var result = lines
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0 where !result.isEmpty:
                result.remove(at: Int.random(in: 0..<result.count, using: &rng))
            case 1 where !result.isEmpty:
                counter += 1
                result[Int.random(in: 0..<result.count, using: &rng)] = "edit\(counter)"
            default:
                counter += 1
                result.insert("new\(counter)", at: Int.random(in: 0...result.count, using: &rng))
            }
        }
        return result
    }

    private static func textLines(_ record: ThoughtContentRecord) -> [String] {
        ([record.body] + record.blocks.filter { $0.resolved?.kind == .markdown }.map(\.content)).flatMap { $0.split(separator: "\n").map(String.init) }
    }

    @Test(arguments: Array<UInt64>(1...60))
    func aCleanMergeKeepsEveryAddedLineAndNoRemovedOne(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var counter = 0
        let baseBody = Self.lines("body", Int.random(in: 2...8, using: &rng))
        let baseBlocks = (1...Int.random(in: 1...3, using: &rng)).map { Self.lines("blk\($0)_", Int.random(in: 1...6, using: &rng)) }
        let base = Self.content(Self.text(baseBody), blocks: baseBlocks.enumerated().map { Self.md($0.offset + 1, Self.text($0.element)) })
        func edit(_ salt: Int) -> ThoughtContentRecord {
            let body = Self.editedText(baseBody, &counter, &rng)
            var blocks = baseBlocks.enumerated().compactMap { index, lines -> BlockRecord? in
                let edited = Self.editedText(lines, &counter, &rng)
                return edited.isEmpty ? nil : Self.md(index + 1, Self.text(edited))
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                counter += 1
                blocks.append(Self.md(100 + salt, "added\(counter)"))
            }
            if Int.random(in: 0..<5, using: &rng) == 0, blocks.count > 1 { blocks.shuffle(using: &rng) }
            return Self.content(Self.text(body), blocks: blocks, updated: Double(salt))
        }
        for _ in 0..<12 {
            let local = edit(1), remote = edit(2)
            let allBase = Set(Self.textLines(base))
            guard case .merged(let result) = ContentMerge.merge(base: base, local: local, remote: remote) else { continue }
            let kept = Set(Self.textLines(result))
            for side in [local, remote] {
                let lines = Set(Self.textLines(side))
                #expect(lines.subtracting(allBase).isSubset(of: kept), "seed \(seed): an added line is missing")
                #expect(allBase.subtracting(lines).isDisjoint(with: kept), "seed \(seed): a removed line came back")
            }
        }
    }

    @Test(arguments: Array<UInt64>(1...30))
    func anUnchangedSideAlwaysYieldsTheOtherSide(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var counter = 0
        let lines = Self.lines("l", 6)
        let base = Self.content(Self.text(lines), blocks: [Self.md(1, "x\ny"), Self.gallery(2, [10, 11])], images: [])
        let changed = Self.content(
            Self.text(Self.editedText(lines, &counter, &rng)),
            blocks: [Self.md(1, "x\ny\nz"), Self.gallery(2, [10])], updated: 5
        )
        #expect(Self.merged(base, base, changed) == changed)
        #expect(Self.merged(base, changed, base) == changed)
    }

    @Test(arguments: Array<UInt64>(1...40))
    func imageTokensAreNeverDuplicatedOrDropped(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let baseTokens = Array(1...3)
        func body(_ order: [Int], extra: [Int]) -> String {
            let lines = Self.lines("t", 6)
            var all = lines
            for token in order + extra { all.insert(Self.token(token), at: Int.random(in: 0...all.count, using: &rng)) }
            return Self.text(all)
        }
        let baseLines = Self.lines("t", 6)
        var baseBody = baseLines
        for token in baseTokens { baseBody.insert(Self.token(token), at: Int.random(in: 0...baseBody.count, using: &rng)) }
        let base = Self.content(Self.text(baseBody), images: baseTokens)
        func side(_ added: Int) -> ThoughtContentRecord {
            var lines = baseBody
            var kept = baseTokens
            for token in baseTokens where Int.random(in: 0..<3, using: &rng) == 0 {
                lines.removeAll { $0 == Self.token(token) }
                kept.removeAll { $0 == token }
                if Bool.random(using: &rng) {
                    lines.insert(Self.token(token), at: Int.random(in: 0...lines.count, using: &rng))
                    kept.append(token)
                }
            }
            if Bool.random(using: &rng) {
                lines.insert(Self.token(added), at: Int.random(in: 0...lines.count, using: &rng))
                kept.append(added)
            }
            return Self.content(Self.text(lines), images: kept)
        }
        let local = side(10), remote = side(20)
        guard case .merged(let result) = ContentMerge.merge(base: base, local: local, remote: remote) else { return }
        let found = ImageToken.references(in: result.body)
        #expect(Set(found).count == found.count, "seed \(seed): a token appears twice")
        #expect(Set(found) == Set(result.images.map(\.id)), "seed \(seed): images and tokens differ")
        for token in [10, 20] {
            let wanted = [local, remote].contains { ImageToken.references(in: $0.body).contains(Self.id(token)) }
            #expect(found.contains(Self.id(token)) == wanted, "seed \(seed): token \(token)")
        }
        for token in baseTokens {
            let present = [local, remote].map { ImageToken.references(in: $0.body).contains(Self.id(token)) }
            if present == [true, true] { #expect(found.contains(Self.id(token)), "seed \(seed): a kept token was dropped") }
            if present == [false, false] { #expect(!found.contains(Self.id(token)), "seed \(seed): a removed token is back") }
        }
    }
}
