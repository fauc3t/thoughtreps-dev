import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

func fakeImage(_ tag: UInt8 = 1) -> ProcessedImage {
    ProcessedImage(data: Data([tag, 1]), thumbnailData: Data([tag]), width: 40, height: 30)
}

func newImage(_ tag: UInt8 = 1) -> ImageDraft {
    ImageDraft(processed: fakeImage(tag))
}

private struct DiskFull: Error {}

@MainActor
@Suite("Images in the store")
struct ImageStoreTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let container: ModelContainer
    let context: ModelContext
    let store: ThoughtStore
    let isolated = IsolatedDefaults()

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        context = container.mainContext
        store = ThoughtStore(
            context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
    }

    func makeStore(save: @escaping (ModelContext) throws -> Void) -> ThoughtStore {
        ThoughtStore(
            context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: save,
            pendingImageSaves: isolated.pendingImageSaves
        )
    }

    func imageCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<ImageAsset>())
    }

    func checkClean() throws {
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    func gallery(_ images: [ImageDraft], title: String = "") -> BlockDraft {
        BlockDraft(kind: .gallery, title: title, images: images)
    }

    @Test func createKeepsInlineImagesWithTokensAndDiscardsTheRest() throws {
        let used = newImage(1)
        let unused = newImage(2)
        let thought = store.create(body: "# T\n\(ImageToken.token(for: used.id))", images: [used, unused], now: now)
        #expect(thought.modelContext != nil)
        let images = try #require(thought.images)
        #expect(images.map(\.id) == [used.id])
        #expect(images[0].block == nil)
        #expect(images[0].data == Data([1, 1]))
        #expect(images[0].thumbnailData == Data([1]))
        #expect(images[0].width == 40 && images[0].height == 30)
        #expect(try imageCount() == 1)
        try checkClean()
    }

    @Test func updateAddsKeepsAndRemovesInlineImages() throws {
        let first = newImage(1)
        let thought = store.create(body: "# T\n\(ImageToken.token(for: first.id))", images: [first], now: now)
        let later = now.addingTimeInterval(60)

        let second = newImage(2)
        let unused = newImage(3)
        let body = "# T\n\(ImageToken.token(for: first.id)) and \(ImageToken.token(for: second.id))"
        #expect(store.update(thought, body: body, blocks: [], images: [second, unused], intervalDays: nil, now: later))
        #expect(Set((thought.images ?? []).map(\.id)) == [first.id, second.id])
        #expect(thought.updatedAt == later)
        try checkClean()

        #expect(store.update(thought, body: "# T\n\(ImageToken.token(for: second.id))", blocks: [], intervalDays: nil, now: later))
        #expect((thought.images ?? []).map(\.id) == [second.id])
        #expect(try imageCount() == 1)

        #expect(store.update(thought, body: "# T", blocks: [], intervalDays: nil, now: later))
        #expect(try imageCount() == 0)
        try checkClean()
    }

    @Test func tokensInCodeDoNotKeepImages() throws {
        let image = newImage()
        let thought = store.create(body: "# T\n`\(ImageToken.token(for: image.id))`", images: [image], now: now)
        #expect(try imageCount() == 0)
        #expect(thought.modelContext != nil)
        try checkClean()
    }

    @Test func galleryCreateReorderAddAndRemove() throws {
        let a = newImage(1), b = newImage(2), c = newImage(3)
        let thought = store.create(body: "# T", blocks: [gallery([a, b, c], title: "Trip")], now: now)
        let block = try #require(thought.sortedBlocks.first)
        #expect(block.kind == .gallery)
        #expect(block.title == "Trip")
        #expect(block.content == "")
        #expect(block.sortedImages.map(\.id) == [a.id, b.id, c.id])
        #expect(block.sortedImages.map(\.order) == [0, 1, 2])
        #expect(block.sortedImages.allSatisfy { $0.thought === thought })
        try checkClean()

        let d = newImage(4)
        let edited = BlockDraft(id: block.id, kind: .gallery, title: "Trip", images: [
            ImageDraft(id: c.id), d, ImageDraft(id: a.id),
        ])
        #expect(store.update(thought, body: "# T", blocks: [edited], intervalDays: nil, now: now))
        #expect(block.sortedImages.map(\.id) == [c.id, d.id, a.id])
        #expect(block.sortedImages.map(\.order) == [0, 1, 2])
        #expect(try imageCount() == 3)
        try checkClean()
    }

    @Test func galleryDraftsDropEmptyGalleriesAndUnknownReferences() throws {
        let thought = store.create(
            body: "# T",
            blocks: [gallery([]), gallery([ImageDraft(id: UUID())]), gallery([newImage()])],
            now: now
        )
        #expect(thought.sortedBlocks.count == 1)
        #expect(try imageCount() == 1)
        try checkClean()
    }

    @Test func removingAGalleryDeletesItsImages() throws {
        let one = gallery([newImage(1), newImage(2)])
        let two = gallery([newImage(3)])
        let blurred = BlockDraft(content: "hidden")
        let thought = store.create(body: "# T", blocks: [blurred, one, two], now: now)
        #expect(thought.sortedBlocks.map(\.kind) == [.blurred, .gallery, .gallery])

        let keep = BlockDraft(id: two.id, kind: .gallery, images: [ImageDraft(id: two.images[0].id)])
        #expect(store.update(thought, body: "# T", blocks: [keep], intervalDays: nil, now: now))
        #expect(thought.sortedBlocks.map(\.id) == [two.id])
        #expect(thought.sortedBlocks[0].order == 0)
        #expect(try imageCount() == 1)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 1)
        try checkClean()

        #expect(store.update(thought, body: "# T", blocks: [], intervalDays: nil, now: now))
        #expect(try imageCount() == 0)
        try checkClean()
    }

    @Test func removingAllImagesFromAGalleryRemovesTheGallery() throws {
        let draft = gallery([newImage()])
        let thought = store.create(body: "# T", blocks: [draft], now: now)
        let emptied = BlockDraft(id: draft.id, kind: .gallery, images: [])
        #expect(store.update(thought, body: "# T", blocks: [emptied], intervalDays: nil, now: now))
        #expect((thought.blocks ?? []).isEmpty)
        #expect(try imageCount() == 0)
        try checkClean()
    }

    @Test func deleteAndDeleteAllRemoveEveryImage() throws {
        let inline = newImage()
        let body = "# T\n\(ImageToken.token(for: inline.id))"
        let first = store.create(body: body, blocks: [gallery([newImage(), newImage()])], images: [inline], now: now)
        store.create(body: "# U", blocks: [gallery([newImage()])], now: now)
        #expect(try imageCount() == 4)

        #expect(store.delete(first))
        #expect(try imageCount() == 1)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 1)
        try checkClean()

        #expect(store.deleteAll())
        #expect(try imageCount() == 0)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)
    }

    @Test func orderedImagesPutInlineFirstInBodyOrderThenGalleries() throws {
        let i1 = newImage(1), i2 = newImage(2)
        let g1 = gallery([newImage(3), newImage(4)]), g2 = gallery([newImage(5)])
        let body = "# T\n\(ImageToken.token(for: i2.id))\ntext \(ImageToken.token(for: i1.id)) \(ImageToken.token(for: i2.id))"
        let thought = store.create(body: body, blocks: [g1, g2], images: [i1, i2], now: now)
        let expected = [i2.id, i1.id] + g1.images.map(\.id) + g2.images.map(\.id)
        #expect(thought.orderedImages.map(\.id) == expected)
        #expect(thought.firstImage?.id == i2.id)

        let galleryOnly = store.create(body: "# G", blocks: [gallery([newImage(9)])], now: now)
        #expect(galleryOnly.firstImage?.id == galleryOnly.sortedBlocks[0].sortedImages[0].id)
        let none = store.create(body: "# N", now: now)
        #expect(none.firstImage == nil)
        try checkClean()
    }

    @Test func sampleDataIncludesImagesAndStaysConsistent() throws {
        SampleData.insert(into: context, now: now)
        let thoughts = try context.fetch(FetchDescriptor<Thought>())
        #expect(thoughts.contains { !($0.images ?? []).isEmpty && $0.sortedBlocks.isEmpty })
        #expect(thoughts.contains { $0.sortedBlocks.contains { $0.kind == .gallery && $0.sortedImages.count == 3 } })
        try checkClean()
    }

    @Test func duplicateAndCollidingIdsAreSkippedNotTrapped() throws {
        let inline = newImage(1)
        let shared = newImage(2)
        let galleryDraft = gallery([newImage(3)])
        let thought = store.create(
            body: "# T\n\(ImageToken.token(for: inline.id))",
            blocks: [galleryDraft],
            images: [inline],
            now: now
        )
        let existingGalleryImage = try #require(thought.sortedBlocks[0].sortedImages.first)

        let dupBlock = BlockDraft(id: galleryDraft.id, kind: .gallery, images: [ImageDraft(existing: existingGalleryImage)])
        let collidingNew = ImageDraft(id: inline.id, processed: fakeImage(9))
        let blocks = [
            dupBlock, dupBlock,
            gallery([shared, shared, collidingNew]),
            gallery([shared]),
            BlockDraft(id: galleryDraft.id, content: "same id as the gallery"),
        ]
        #expect(store.update(thought, body: thought.body, blocks: blocks, images: [shared], intervalDays: nil, now: now))
        #expect(try imageCount() == 3)
        #expect(thought.sortedBlocks.count == 2)
        #expect(thought.sortedBlocks.map(\.kind) == [.gallery, .gallery])
        #expect(thought.sortedBlocks[1].sortedImages.map(\.id) == [shared.id])
        try checkClean()
    }

    @Test func existingImageListedUnderAnotherGalleryStaysInItsOwn() throws {
        let one = gallery([newImage(1), newImage(2)])
        let two = gallery([newImage(3)])
        let thought = store.create(body: "# T", blocks: [one, two], now: now)
        let moved = ImageDraft(id: one.images[0].id)
        let blocks = [
            BlockDraft(id: one.id, kind: .gallery, images: [ImageDraft(id: one.images[1].id)]),
            BlockDraft(id: two.id, kind: .gallery, images: [ImageDraft(id: two.images[0].id), moved]),
        ]
        #expect(store.update(thought, body: "# T", blocks: blocks, intervalDays: nil, now: now))
        #expect(try imageCount() == 3)
        #expect(thought.sortedBlocks[0].sortedImages.map(\.id) == [one.images[1].id, moved.id])
        #expect(thought.sortedBlocks[0].sortedImages.map(\.order) == [0, 1])
        #expect(thought.sortedBlocks[1].sortedImages.map(\.id) == [two.images[0].id])
        try checkClean()
    }

    @Test func imageListedUnderAnotherGalleryKeepsTheEmptiedSourceGallery() throws {
        let one = gallery([newImage(1)])
        let two = gallery([newImage(3)])
        let thought = store.create(body: "# T", blocks: [one, two], now: now)
        let i1 = one.images[0].id
        let blocks = [
            BlockDraft(id: one.id, kind: .gallery, images: []),
            BlockDraft(id: two.id, kind: .gallery, images: [ImageDraft(id: two.images[0].id), ImageDraft(id: i1)]),
        ]
        #expect(store.update(thought, body: "# T", blocks: blocks, intervalDays: nil, now: now))
        #expect(try imageCount() == 2)
        #expect(thought.sortedBlocks.map(\.id) == [one.id, two.id])
        #expect(thought.sortedBlocks[0].sortedImages.map(\.id) == [i1])
        #expect(thought.sortedBlocks[1].sortedImages.map(\.id) == [two.images[0].id])
        try checkClean()
    }

    @Test func failedCreateLeavesNothingBehind() throws {
        let failing = makeStore(save: { _ in throw DiskFull() })
        let inline = newImage()
        let thought = failing.create(
            body: "# T\n\(ImageToken.token(for: inline.id))", blocks: [gallery([newImage()])], images: [inline], now: now
        )
        #expect(thought.modelContext == nil)
        #expect(try imageCount() == 0)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)
        try checkClean()
    }

    /// Everything `update` can do to images at once, failing at each of its saves.
    @Test(arguments: 1...6)
    func complexUpdateFailingAtAnySaveIsConsistentAndRetrySucceeds(failingStep: Int) throws {
        let i1 = newImage(1), i2 = newImage(2)
        let a = newImage(3), b = newImage(4), c = newImage(5), d = newImage(6)
        let g1 = gallery([a, b, c], title: "One"), g2 = gallery([d])
        let blurred = BlockDraft(content: "hidden")
        let body = "# T\n#swift\n\(ImageToken.token(for: i1.id)) \(ImageToken.token(for: i2.id))"
        let thought = store.create(body: body, blocks: [blurred, g1, g2], images: [i1, i2], now: now)
        try checkClean()

        let n1 = newImage(7), x = newImage(8), y = newImage(9)
        let newBody = "# T\n#other\n\(ImageToken.token(for: i2.id)) \(ImageToken.token(for: n1.id))"
        let blocks = [
            BlockDraft(content: "hidden 2"),
            gallery([y]),
            BlockDraft(id: g1.id, kind: .gallery, title: "One", images: [ImageDraft(id: c.id), x, ImageDraft(id: a.id)]),
        ]

        var calls = 0
        let flaky = makeStore(save: {
            calls += 1
            if calls == failingStep { throw DiskFull() }
            try $0.save()
        })
        let succeeded = flaky.update(thought, body: newBody, blocks: blocks, images: [n1], intervalDays: 3, now: now)
        #expect(!succeeded, Comment(rawValue: "failing step \(failingStep)"))
        let failure = Comment(rawValue: "failing step \(failingStep)")
        #expect(try IntegrityChecker.check(context).isEmpty, failure)

        #expect(store.update(thought, body: newBody, blocks: blocks, images: [n1], intervalDays: 3, now: now))
        #expect(thought.body == newBody, failure)
        #expect(thought.sortedBlocks.map(\.kind) == [.blurred, .gallery, .gallery], failure)
        #expect(thought.sortedBlocks.map(\.order) == [0, 1, 2], failure)
        #expect(thought.sortedBlocks[1].sortedImages.map(\.id) == [y.id], failure)
        #expect(thought.sortedBlocks[2].sortedImages.map(\.id) == [c.id, x.id, a.id], failure)
        #expect(thought.sortedBlocks[2].sortedImages.map(\.order) == [0, 1, 2], failure)
        #expect(thought.orderedImages.map(\.id) == [i2.id, n1.id, y.id, c.id, x.id, a.id], failure)
        #expect(try imageCount() == 6, failure)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 3, failure)
        #expect(try IntegrityChecker.check(context).isEmpty, failure)
    }

    @Test
    func failedDeleteRestoresImages() throws {
        let inline = newImage()
        let thought = store.create(
            body: "# T\n\(ImageToken.token(for: inline.id))", blocks: [gallery([newImage(), newImage()])], images: [inline], now: now
        )
        let failing = makeStore(save: { _ in throw DiskFull() })
        #expect(!failing.delete(thought))
        #expect(!failing.deleteAll())
        #expect(try imageCount() == 3)
        #expect(thought.orderedImages.count == 3)
        try checkClean()
    }
}

/// Each image rule the checker enforces must be noticed, or the randomized tests prove nothing.
@MainActor
@Suite("IntegrityChecker images")
struct ImageIntegrityTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A thought with one inline image and a two-image gallery, then `damage`.
    func violations(after damage: (ModelContext, Thought) -> Void) throws -> [String] {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        let inline = newImage()
        let thought = store.create(
            body: "# T\n\(ImageToken.token(for: inline.id))",
            blocks: [BlockDraft(content: "hidden"), BlockDraft(kind: .gallery, images: [newImage(), newImage()])],
            images: [inline],
            now: now
        )
        #expect(try IntegrityChecker.check(context).isEmpty)
        damage(context, thought)
        return try IntegrityChecker.check(context).map(\.description)
    }

    func galleryImages(_ thought: Thought) -> [ImageAsset] {
        thought.sortedBlocks[1].sortedImages
    }

    @Test func detectsDuplicateIDs() throws {
        let found = try violations { context, thought in
            let image = thought.images!.first!
            let copy = ImageAsset(id: image.id, data: Data([1]), thumbnailData: Data([1]), width: 1, height: 1)
            context.insert(copy)
            copy.thought = thought
            let block = thought.sortedBlocks[0]
            let twin = Block(id: block.id, kind: .blurred, content: "x", order: 5)
            context.insert(twin)
            twin.thought = thought
        }
        #expect(found.contains { $0.contains("Duplicate image id") })
        #expect(found.contains { $0.contains("Duplicate block id") })
    }

    @Test func detectsMissingData() throws {
        let found = try violations { _, thought in
            thought.images?.first?.data = nil
            thought.images?.last?.thumbnailData = nil
        }
        #expect(found.filter { $0.contains("missing its data") }.count == 2)
    }

    @Test func detectsInlineImageWithoutToken() throws {
        let found = try violations { _, thought in thought.body = "# T" }
        #expect(found.contains { $0.contains("Inline image") && $0.contains("no token") })
    }

    @Test func detectsTokenWithoutImage() throws {
        let found = try violations { _, thought in thought.body += "\n\(ImageToken.token(for: UUID()))" }
        #expect(found.contains { $0.contains("references image") })
    }

    @Test func detectsGalleryImageOfAnotherThought() throws {
        let found = try violations { context, thought in
            let other = Thought(body: "other", nextDueAt: now)
            context.insert(other)
            galleryImages(thought)[0].thought = other
        }
        #expect(found.contains { $0.contains("different thought") })
    }

    @Test func detectsGalleryOrderGap() throws {
        let found = try violations { _, thought in galleryImages(thought)[1].order = 5 }
        #expect(found.contains { $0.contains("image orders") })
    }

    @Test func detectsImagesInBlurredBlocks() throws {
        let found = try violations { _, thought in
            galleryImages(thought)[0].block = thought.sortedBlocks[0]
        }
        #expect(found.contains { $0.contains("not a gallery") })
        #expect(found.contains { $0.contains("Blurred block") && $0.contains("has images") })
    }
}
