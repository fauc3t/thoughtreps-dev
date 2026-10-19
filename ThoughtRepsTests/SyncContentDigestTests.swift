#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync content digest")
struct SyncContentDigestTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore() throws -> (ModelContainer, ThoughtStore) {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let defaults = UserDefaults(suiteName: "SyncContentDigestTests.\(UUID().uuidString)")!
        return (container, ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway(), syncDefaults: defaults))
    }

    private func digest(_ container: ModelContainer) throws -> String {
        try SyncContentDigest.compute(in: container).digest
    }

    @Test func anEmptyStoreHasAStableDigest() throws {
        let (a, _) = try makeStore()
        let (b, _) = try makeStore()
        #expect(try digest(a) == digest(b))
        #expect(try SyncContentDigest.compute(in: a).count == 0)
    }

    @Test func theDigestIsStableAcrossCalls() throws {
        let (container, store) = try makeStore()
        store.create(body: "One\n#tag", now: now)
        #expect(try digest(container) == digest(container))
    }

    @Test func insertionOrderDoesNotMatter() throws {
        let (a, storeA) = try makeStore()
        let (b, storeB) = try makeStore()
        let one = storeA.create(body: "One", now: now)
        let two = storeA.create(body: "Two\n#x", now: now)
        for source in [two, one] {
            let copy = storeB.create(body: source.body, now: now)
            copy.id = source.id
            copy.createdAt = source.createdAt
            copy.nextDueAt = source.nextDueAt
        }
        try storeB.context.save()
        #expect(try digest(a) == digest(b))
    }

    @Test func contentTagsStateAndScheduleAllChangeTheDigest() throws {
        let (container, store) = try makeStore()
        let thought = store.create(body: "One\n#tag", now: now)
        var seen = [try digest(container)]
        func changed() throws -> Bool {
            let value = try digest(container)
            defer { seen.append(value) }
            return !seen.contains(value)
        }
        store.update(thought, body: "One edited\n#tag", blocks: [], intervalDays: nil, now: now.addingTimeInterval(1))
        #expect(try changed())
        store.update(thought, body: "One edited\n#tag #other", blocks: [], intervalDays: nil, now: now.addingTimeInterval(2))
        #expect(try changed())
        store.setPinned(thought, true, now: now.addingTimeInterval(3))
        #expect(try changed())
        store.setInterval(thought, days: 30, now: now.addingTimeInterval(4))
        #expect(try changed())
        store.setLearnMode(thought, true, now: now.addingTimeInterval(5))
        #expect(try changed())
        store.archive(thought, now: now.addingTimeInterval(6))
        #expect(try changed())
    }

    @Test func imageAndFileBytesChangeTheDigest() async throws {
        let (container, store) = try makeStore()
        await SyncTestSeed.run(.init(kind: .gallery, nonce: "a"), store: store, now: now, defaults: UserDefaults(suiteName: "d.\(UUID().uuidString)")!)
        await SyncTestSeed.run(.init(kind: .file, nonce: "a"), store: store, now: now, defaults: UserDefaults(suiteName: "d.\(UUID().uuidString)")!)
        let before = try digest(container)
        let image = try #require(try container.mainContext.fetch(FetchDescriptor<ImageAsset>()).first)
        image.data = (image.data ?? Data()) + Data([0])
        try container.mainContext.save()
        let afterImage = try digest(container)
        #expect(afterImage != before)
        let file = try #require(try container.mainContext.fetch(FetchDescriptor<FileAsset>()).first)
        file.data = Data("changed".utf8)
        try container.mainContext.save()
        #expect(try digest(container) != afterImage)
    }

    @Test func changeClocksAndTagColorsChangeTheDigest() throws {
        let (container, store) = try makeStore()
        let thought = store.create(body: "One\n#tag", now: now)
        let before = try digest(container)
        thought.updatedAt = now.addingTimeInterval(500)
        try container.mainContext.save()
        let afterContent = try digest(container)
        #expect(afterContent != before)
        thought.scheduleChangedAt = now.addingTimeInterval(500)
        try container.mainContext.save()
        let afterSchedule = try digest(container)
        #expect(afterSchedule != afterContent)
        thought.stateChangedAt = now.addingTimeInterval(500)
        try container.mainContext.save()
        let afterState = try digest(container)
        #expect(afterState != afterSchedule)
        let tag = try #require(thought.tags?.first)
        store.setColor(tag, hex: "#3352D1", now: now.addingTimeInterval(600))
        #expect(try digest(container) != afterState)
    }

    @Test func viewCountsDoNotChangeTheDigest() throws {
        let (container, store) = try makeStore()
        let thought = store.create(body: "One\n#tag", now: now)
        let before = try digest(container)
        thought.viewCount = 9
        thought.lastViewedAt = now
        try container.mainContext.save()
        #expect(try digest(container) == before)
    }

    @Test func morePagesThanOneStillHash() throws {
        let (container, store) = try makeStore()
        for number in 1...(SyncContentDigest.pageSize + 5) { store.create(body: "Thought \(number)", now: now) }
        let result = try SyncContentDigest.compute(in: container)
        #expect(result.count == SyncContentDigest.pageSize + 5)
    }
}
#endif
