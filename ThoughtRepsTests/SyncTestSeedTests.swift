#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync test seed")
struct SyncTestSeedTests {
    let container: ModelContainer
    let store: ThoughtStore
    let defaults: UserDefaults
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        defaults = UserDefaults(suiteName: "SyncTestSeedTests.\(UUID().uuidString)")!
        store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway(), syncDefaults: defaults)
    }

    private func thoughts() throws -> [Thought] {
        try container.mainContext.fetch(FetchDescriptor<Thought>())
    }

    @Test func requestsAreParsedFromTheLaunchArguments() {
        #expect(SyncTestSeed.requests(in: ["app", "-TRSeedSyncTestData", "gallery:n1"]) == [.init(kind: .gallery, nonce: "n1")])
        #expect(SyncTestSeed.requests(in: ["app", "-TRSeedSyncTestData", "bulk"]) == [.init(kind: .bulk, nonce: "")])
        #expect(
            SyncTestSeed.requests(in: ["app", "-TRSeedSyncTestData", "image,file,nope:n2"])
                == [.init(kind: .image, nonce: "n2"), .init(kind: .file, nonce: "n2")]
        )
        #expect(SyncTestSeed.requests(in: ["app", "-TRSeedSyncTestData", "other"]).isEmpty)
        #expect(SyncTestSeed.requests(in: ["app", "-TRSeedSyncTestData"]).isEmpty)
        #expect(SyncTestSeed.requests(in: ["app"]).isEmpty)
    }

    @Test func aLearnSeedIsDueNow() async throws {
        await SyncTestSeed.run(.init(kind: .learn, nonce: "a"), store: store, now: now, defaults: defaults)
        let thought = try #require(try thoughts().first)
        #expect(thought.intervalMode == .learn)
        #expect(thought.isDue(now: now))
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func anInlineImageThoughtHasItsImageAndToken() async throws {
        await SyncTestSeed.run(.init(kind: .image, nonce: "a"), store: store, now: now, defaults: defaults)
        let thought = try #require(try thoughts().first)
        #expect(thought.title == "Seed image")
        #expect(thought.sortedTags.map(\.name) == ["syncprobe"])
        let image = try #require(thought.images?.first)
        #expect(thought.images?.count == 1 && image.isInline && image.data?.isEmpty == false)
        #expect(thought.inlineImageReferences == [image.id])
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func aGalleryHoldsThreeDistinctImagesInOrder() async throws {
        await SyncTestSeed.run(.init(kind: .gallery, nonce: "a"), store: store, now: now, defaults: defaults)
        let thought = try #require(try thoughts().first)
        let gallery = try #require(thought.sortedBlocks.first)
        #expect(gallery.kind == .gallery)
        #expect(gallery.sortedImages.map(\.order) == [0, 1, 2])
        #expect(Set(gallery.sortedImages.compactMap(\.data)).count == 3)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func aFileBlockHoldsTheSeedFile() async throws {
        await SyncTestSeed.run(.init(kind: .file, nonce: "a"), store: store, now: now, defaults: defaults)
        let file = try #require(try thoughts().first?.sortedBlocks.first?.file)
        #expect(file.filename == "seed-notes.txt")
        #expect(file.data == SyncTestSeed.fileBytes())
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func bulkMakesFiveHundredNumberedThoughts() async throws {
        await SyncTestSeed.run(.init(kind: .bulk, nonce: "a"), store: store, now: now, defaults: defaults)
        let bodies = Set(try thoughts().map(\.body))
        #expect(bodies.count == 500)
        #expect(bodies.contains(SyncTestSeed.bulkBody(1)) && bodies.contains(SyncTestSeed.bulkBody(500)))
    }

    @Test func theLargeThoughtIsOverTheInlineLimit() async throws {
        await SyncTestSeed.run(.init(kind: .large, nonce: "a"), store: store, now: now, defaults: defaults)
        let thought = try #require(try thoughts().first)
        #expect(thought.body.utf8.count >= SyncTestSeed.largeBodyBytes)
        #expect(SyncTestSeed.largeBodyBytes > SyncLimits.maxInlinePayload)
    }

    @Test func theSameKindAndNonceSeedsOnce() async throws {
        let request = SyncTestSeed.Request(kind: .image, nonce: "n1")
        #expect(await SyncTestSeed.run(request, store: store, now: now, defaults: defaults))
        #expect(!(await SyncTestSeed.run(request, store: store, now: now, defaults: defaults)))
        #expect(try thoughts().count == 1)
        #expect(await SyncTestSeed.run(.init(kind: .image, nonce: "n2"), store: store, now: now, defaults: defaults))
        #expect(try thoughts().count == 2)
    }

    @Test func twoRunsMakeTheSameStructureAndBytes() async throws {
        let other = try ModelContainer.thoughtReps(inMemory: true)
        let otherStore = ThoughtStore(context: other.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway(), syncDefaults: defaults)
        for kind in [SyncTestSeed.Kind.image, .gallery, .file, .large, .learn] {
            await SyncTestSeed.run(.init(kind: kind, nonce: "a"), store: store, now: now, defaults: defaults)
            await SyncTestSeed.run(.init(kind: kind, nonce: "b"), store: otherStore, now: now, defaults: defaults)
        }
        let first = try SyncContentDigest.compute(in: container)
        let second = try SyncContentDigest.compute(in: other)
        #expect(first.count == 5 && second.count == 5)
        let shape = { (context: ModelContext) throws -> [String] in
            try context.fetch(FetchDescriptor<Thought>()).map { thought in
                let images = (thought.images ?? []).map { "\($0.id) \($0.width)x\($0.height) \($0.order) \($0.data?.count ?? 0)" }.sorted()
                return "\(thought.body.count) \(images) \((thought.files ?? []).map(\.byteCount))"
            }.sorted()
        }
        #expect(try shape(container.mainContext) == shape(other.mainContext))
    }
}
#endif
