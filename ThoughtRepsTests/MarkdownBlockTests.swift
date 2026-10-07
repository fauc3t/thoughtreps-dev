import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Markdown blocks")
struct MarkdownBlockTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let container: ModelContainer
    let context: ModelContext
    let store: ThoughtStore
    let index = SearchIndex(location: .inMemory)
    let isolated = IsolatedDefaults()

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        context = container.mainContext
        var store = ThoughtStore(
            context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
        store.searchIndex = index
        self.store = store
    }

    func checkClean() throws {
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    func imageCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<ImageAsset>())
    }

    // MARK: Persistence

    @Test func blurStateAndTitleArePersistedAndEdited() throws {
        let draft = BlockDraft(title: "Answer", content: "O(1)", isBlurred: true)
        let thought = store.create(body: "# Q", blocks: [draft, BlockDraft(content: "plain")], now: now)
        #expect(thought.sortedBlocks.map(\.kind) == [.markdown, .markdown])
        #expect(thought.sortedBlocks.map(\.isBlurred) == [true, false])
        #expect(BlockDraft.drafts(for: thought).map(\.isBlurred) == [true, false])

        var drafts = BlockDraft.drafts(for: thought)
        drafts[0].isBlurred = false
        drafts[1].isBlurred = true
        #expect(store.update(thought, body: "# Q", blocks: drafts, intervalDays: nil, now: now))
        #expect(thought.sortedBlocks.map(\.isBlurred) == [false, true])
        try checkClean()
    }

    @Test func blankMarkdownBlocksAreDropped() throws {
        let thought = store.create(body: "# Q", blocks: [BlockDraft(content: "  "), BlockDraft(content: "x")], now: now)
        #expect(thought.sortedBlocks.map(\.content) == ["x"])
        try checkClean()
    }

    // MARK: Tags

    @Test func tagsComeFromEveryMarkdownBlock() throws {
        let thought = store.create(
            body: "# Q #body",
            blocks: [BlockDraft(content: "#hidden", isBlurred: true), BlockDraft(content: "#shown")],
            now: now
        )
        #expect(thought.sortedTags.map(\.name) == ["body", "hidden", "shown"])
        try checkClean()

        var drafts = BlockDraft.drafts(for: thought)
        drafts[0].content = "#other"
        drafts.append(BlockDraft(content: "#added"))
        #expect(store.update(thought, body: "# Q #body", blocks: drafts, intervalDays: nil, now: now))
        #expect(thought.sortedTags.map(\.name) == ["added", "body", "other", "shown"])
        try checkClean()

        #expect(store.update(thought, body: "# Q", blocks: [], intervalDays: nil, now: now))
        #expect(thought.sortedTags.isEmpty)
        try checkClean()
    }

    @Test func tagsAtTheEdgesOfSeparateBlocksStaySeparate() throws {
        let thought = store.create(body: "# Q #a", blocks: [BlockDraft(content: "b #c")], now: now)
        #expect(thought.sortedTags.map(\.name) == ["a", "c"])
    }

    // MARK: Inline images

    func imageBlock(_ image: ImageDraft, id: UUID = UUID()) -> BlockDraft {
        BlockDraft(id: id, content: "see\n\(ImageToken.token(for: image.id))")
    }

    @Test func createKeepsAnInlineImageReferencedOnlyByABlock() throws {
        let image = newImage(1)
        let thought = store.create(body: "# Q", blocks: [imageBlock(image)], images: [image], now: now)
        #expect(thought.images?.map(\.id) == [image.id])
        #expect(thought.images?.first?.block == nil)
        #expect(thought.orderedImages.map(\.id) == [image.id])
        try checkClean()
    }

    @Test func updateKeepsAddsAndRemovesBlockImagesByToken() throws {
        let first = newImage(1)
        let blockID = UUID()
        let thought = store.create(body: "# Q", blocks: [imageBlock(first, id: blockID)], images: [first], now: now)

        // Dropping the token from the block deletes the image.
        #expect(store.update(thought, body: "# Q", blocks: [BlockDraft(id: blockID, content: "no image")], intervalDays: nil, now: now))
        #expect(try imageCount() == 0)
        try checkClean()

        // A new image referenced by a kept block is saved.
        let second = newImage(2)
        #expect(store.update(thought, body: "# Q", blocks: [imageBlock(second, id: blockID)], images: [second], intervalDays: nil, now: now))
        #expect(thought.images?.map(\.id) == [second.id])
        try checkClean()

        // A new image referenced only by a new block is saved with that block.
        let third = newImage(3)
        var drafts = BlockDraft.drafts(for: thought)
        drafts.append(imageBlock(third))
        #expect(store.update(thought, body: "# Q", blocks: drafts, images: [third], intervalDays: nil, now: now))
        #expect(Set((thought.images ?? []).map(\.id)) == [second.id, third.id])
        try checkClean()

        // Removing a block deletes the image only it referenced.
        #expect(store.update(thought, body: "# Q", blocks: Array(BlockDraft.drafts(for: thought).prefix(1)), intervalDays: nil, now: now))
        #expect(thought.images?.map(\.id) == [second.id])
        try checkClean()

        // Removing every markdown block deletes the rest.
        #expect(store.update(thought, body: "# Q", blocks: [], intervalDays: nil, now: now))
        #expect(try imageCount() == 0)
        try checkClean()
    }

    @Test func anImageMovedFromTheBodyIntoABlockSurvives() throws {
        let image = newImage(1)
        let thought = store.create(body: "# Q\n\(ImageToken.token(for: image.id))", images: [image], now: now)
        let moved = BlockDraft(content: ImageToken.token(for: image.id))
        #expect(store.update(thought, body: "# Q", blocks: [moved], intervalDays: nil, now: now))
        #expect(thought.images?.map(\.id) == [image.id])
        try checkClean()
    }

    @Test func anImageMovedFromARemovedBlockIntoTheBodySurvives() throws {
        let image = newImage(1)
        let thought = store.create(body: "# Q", blocks: [imageBlock(image)], images: [image], now: now)
        #expect(store.update(thought, body: "# Q\n\(ImageToken.token(for: image.id))", blocks: [], intervalDays: nil, now: now))
        #expect(thought.images?.map(\.id) == [image.id])
        try checkClean()
    }

    @Test func aTokenInABlockWithNoStoredImageIsReported() throws {
        let thought = store.create(body: "# Q", blocks: [BlockDraft(content: "x")], now: now)
        thought.sortedBlocks[0].content += ImageToken.token(for: UUID())
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("text references image") })
    }

    @Test func aFailedSaveLeavesBlockImagesConsistent() throws {
        var failing = store
        let thought = failing.create(body: "# Q", blocks: [BlockDraft(content: "x")], now: now)
        for step in 1...4 {
            let image = newImage(UInt8(step))
            var count = 0
            failing.save = { context in
                count += 1
                if count == step { throw InjectedSaveFailure() }
                try context.save()
            }
            let drafts = [imageBlock(image), BlockDraft(content: "second")]
            _ = failing.update(thought, body: "# Q", blocks: drafts, images: [image], intervalDays: nil, now: now)
            failing.cleanUpPendingImageSaves()
            #expect(try IntegrityChecker.check(context).isEmpty, "failing save \(step)")
            failing.save = { try $0.save() }
            #expect(failing.update(thought, body: "# Q", blocks: [BlockDraft(content: "x")], intervalDays: nil, now: now))
            #expect(try imageCount() == 0)
        }
    }

    // MARK: Search

    @Test func blurredAndPlainMarkdownBlocksAreSearchable() async throws {
        let thought = store.create(
            body: "# Q",
            blocks: [BlockDraft(content: "needleblurred", isBlurred: true), BlockDraft(content: "needleplain")],
            now: now
        )
        #expect(try await index.search("needleblurred", scope: .all).map(\.id) == [thought.id])
        #expect(try await index.search("needleplain", scope: .all).map(\.id) == [thought.id])
    }

    // MARK: Backup

    @Test func recordsDecodeWithoutIsBlurred() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kindRaw":"markdown","content":"x","order":0,"images":[]}"#
        let decoded = try BackupFormat.decoder().decode(BlockRecord.self, from: Data(json.utf8))
        #expect(!decoded.isBlurred)
        #expect(decoded.resolved?.kind == .markdown && decoded.resolved?.isBlurred == false)
    }

    @Test func legacyBlurredRecordsAreMarkdownAndBlurred() throws {
        let legacy = BlockRecord(id: UUID(), kindRaw: "blurred", title: "Answer", content: "#quiz hidden", order: 0, images: [])
        let id = UUID()
        let incoming = record(id: id, body: "# Old archive", blocks: [legacy])
        #expect(incoming.isImportable)

        var tally = ImportTally()
        #expect(store.importThoughts([ImportedThought(record: incoming, images: [:])], tags: [], tally: &tally))
        #expect(tally.added == 1)
        let imported = try #require(context.fetch(FetchDescriptor<Thought>()).first)
        let block = try #require(imported.sortedBlocks.first)
        #expect(block.kind == .markdown && block.kindRaw == "markdown" && block.isBlurred && block.title == "Answer")
        #expect(imported.sortedTags.map(\.name) == ["quiz"])
        try checkClean()

        // Replacing a stored thought takes the same path.
        let newer = record(id: id, body: "# Old archive v2", updatedAt: now.addingTimeInterval(60), blocks: [legacy])
        #expect(store.importThoughts([ImportedThought(record: newer, images: [:])], tags: [], tally: &tally))
        #expect(tally.replaced == 1)
        #expect(imported.sortedBlocks.map(\.isBlurred) == [true])
        try checkClean()
    }

    @Test func inlineImagesInBlocksAreImportable() throws {
        let image = ImageRecord(id: UUID(), width: 10, height: 10, order: 0)
        let block = BlockRecord(id: UUID(), kindRaw: "markdown", title: nil, content: ImageToken.token(for: image.id), order: 0, images: [])
        #expect(record(blocks: [block], images: [image]).isImportable)
        #expect(!record(blocks: [block]).isImportable)

        var tally = ImportTally()
        let incoming = ImportedThought(record: record(blocks: [block], images: [image]), images: [image.id: fakeImage()])
        #expect(store.importThoughts([incoming], tags: [], tally: &tally))
        #expect(try imageCount() == 1)
        try checkClean()
    }

    @Test func exportWritesTheNewShapeAndRoundTrips() async throws {
        let image = try realImage(0.3)
        let thought = store.create(
            body: "# Q",
            blocks: [
                BlockDraft(title: "Answer", content: "hidden #t\n\(ImageToken.token(for: image.id))", isBlurred: true),
                BlockDraft(content: "plain"),
            ],
            images: [image], now: now
        )
        let url = try BackupExporter(container: container, appVersion: "1.0", build: "1").export(now: now)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let destination = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(destination) {} }
        let destinationStore = ThoughtStore(context: destination.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        let preflight = try BackupImporter.preflight(fileURL: url)
        let plan = try BackupImporter.plan(preflight, container: destination)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(destinationStore.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        #expect(tally.added == 1)
        let copy = try #require(destination.mainContext.fetch(FetchDescriptor<Thought>()).first)
        #expect(copy.id == thought.id)
        #expect(copy.sortedBlocks.map(\.kindRaw) == ["markdown", "markdown"])
        #expect(copy.sortedBlocks.map(\.isBlurred) == [true, false])
        #expect(copy.sortedBlocks.map(\.title) == ["Answer", nil])
        #expect(copy.images?.map(\.id) == [image.id])
        #expect(copy.sortedTags.map(\.name) == ["t"])
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func exportStripsTokensOfMissingImagesFromEveryMarkdownText() throws {
        let image = try realImage(0.3)
        let token = ImageToken.token(for: image.id)
        let thought = store.create(
            body: "# Q\n\(token)",
            blocks: [BlockDraft(content: "keep \(token)"), BlockDraft(content: token), BlockDraft(content: "plain")],
            images: [image], now: now
        )
        let exported = ThoughtRecord(thought, hasImage: { _ in false })
        #expect(exported.markdownTexts.allSatisfy { !$0.contains("](img:") })
        #expect(exported.blocks.map(\.content) == ["keep ", "plain"])
        #expect(exported.isImportable)
    }

    @Test func tagsAreParsedPerTextSoAnUnclosedFenceDoesNotSwallowLaterBlocks() throws {
        let thought = store.create(
            body: "# Q #a\n```\nnever closed #hidden",
            blocks: [BlockDraft(content: "later #foo and #a")], now: now
        )
        #expect(thought.sortedTags.map(\.name) == ["a", "foo"])
        try checkClean()

        var drafts = BlockDraft.drafts(for: thought)
        drafts[0].content = "later #bar"
        #expect(store.update(thought, body: thought.body, blocks: drafts, intervalDays: nil, now: now))
        #expect(thought.sortedTags.map(\.name) == ["a", "bar"])
        try checkClean()
        #expect(TagParser.parse(all: ["```\n#x", "#y", "#x #y"]).map(\.key) == ["y", "x"])
    }

    @Test func blurredGalleriesAreNeverImported() throws {
        #expect(BlockKind.resolve(raw: "gallery", isBlurred: true)?.isBlurred == false)
        let image = ImageRecord(id: UUID(), width: 10, height: 10, order: 0)
        let gallery = BlockRecord(id: UUID(), kindRaw: "gallery", title: nil, content: "", order: 0, isBlurred: true, images: [image])
        #expect(!record(blocks: [gallery]).isImportable)
        var fine = gallery
        fine.isBlurred = false
        #expect(record(blocks: [fine]).isImportable)
    }
}
