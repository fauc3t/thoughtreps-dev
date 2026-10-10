import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("ThoughtCounts")
struct ThoughtCountsTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func tag(_ name: String) -> ThoughtReps.Tag {
        let tag = ThoughtReps.Tag(name: name, displayName: name)
        context.insert(tag)
        return tag
    }

    @discardableResult
    private func thought(tags: [ThoughtReps.Tag], dueOffset: TimeInterval = 100, archived: Bool = false) -> Thought {
        let thought = Thought(body: "t", createdAt: now, nextDueAt: now.addingTimeInterval(dueOffset))
        thought.isArchived = archived
        context.insert(thought)
        thought.tags = tags
        return thought
    }

    private func n(_ predicate: Predicate<Thought>) -> Int {
        ThoughtCounts.count(predicate, in: context)
    }

    @Test func countsPerTagExcludeArchivedAndOtherTags() throws {
        let a = tag("a"), b = tag("b")
        thought(tags: [a])
        thought(tags: [a], archived: true)
        thought(tags: [b])
        try context.save()
        #expect(n(ThoughtCounts.active(tag: "a")) == 1)
        #expect(n(ThoughtCounts.active(tag: "b")) == 1)
        #expect(n(ThoughtCounts.active(tag: "missing")) == 0)
        #expect(n(ThoughtCounts.any(tag: "a")) == 2)
    }

    @Test func limitStopsCountingEarly() throws {
        let a = tag("a")
        thought(tags: [a])
        thought(tags: [a], archived: true)
        thought(tags: [a])
        try context.save()
        #expect(ThoughtCounts.count(ThoughtCounts.any(tag: "a"), in: context, limit: 1) == 1)
        #expect(ThoughtCounts.count(ThoughtCounts.any(tag: "missing"), in: context, limit: 1) == 0)
    }

    @Test func multiTagThoughtCountsOncePerTag() throws {
        let a = tag("a"), b = tag("b")
        thought(tags: [a, b])
        try context.save()
        #expect(n(ThoughtCounts.active(tag: "a")) == 1)
        #expect(n(ThoughtCounts.active(tag: "b")) == 1)
        #expect(n(ThoughtCounts.untagged) == 0)
    }

    @Test func dueMatchesSchedulerAtTheBoundary() throws {
        let a = tag("a")
        thought(tags: [a], dueOffset: -1)
        thought(tags: [a], dueOffset: 0)
        thought(tags: [a], dueOffset: 1)
        thought(tags: [a], dueOffset: -1, archived: true)
        thought(tags: [], dueOffset: 0)
        thought(tags: [], dueOffset: 1)
        try context.save()
        #expect(n(ThoughtCounts.due(tag: "a", now: now)) == 2)
        #expect(n(ThoughtCounts.active(tag: "a")) == 3)
        #expect(n(ThoughtCounts.dueUntagged(now: now)) == 1)
        #expect(n(ThoughtCounts.untagged) == 2)
        let all = try context.fetch(FetchDescriptor<Thought>())
        let expected = all.filter { !$0.isArchived && $0.isUntagged && Scheduler.isDue(nextDueAt: $0.nextDueAt, now: now) }
        #expect(expected.count == n(ThoughtCounts.dueUntagged(now: now)))
    }

    @Test func untaggedIncludesNilTagsAndRemovedTagsAndExcludesArchived() throws {
        let a = tag("a")
        let nilTags = thought(tags: [])
        nilTags.tags = nil
        let removed = thought(tags: [a])
        thought(tags: [], archived: true)
        try context.save()
        #expect(n(ThoughtCounts.untagged) == 1)
        removed.tags = []
        try context.save()
        #expect(n(ThoughtCounts.untagged) == 2)
        #expect(n(ThoughtCounts.active(tag: "a")) == 0)
    }

    @Test func anyCountsArchivedThoughts() throws {
        let a = tag("a")
        thought(tags: [a], archived: true)
        try context.save()
        #expect(n(ThoughtCounts.any(tag: "a")) == 1)
        #expect(n(ThoughtCounts.active(tag: "a")) == 0)
    }

    @Test func perTagDueMatchesScheduler() throws {
        let a = tag("a")
        for offset: TimeInterval in [-1, 0, 1] {
            thought(tags: [a], dueOffset: offset)
            thought(tags: [a], dueOffset: offset, archived: true)
        }
        try context.save()
        let all = try context.fetch(FetchDescriptor<Thought>())
        let expected = all.filter { !$0.isArchived && Scheduler.isDue(nextDueAt: $0.nextDueAt, now: now) }.count
        #expect(expected == 2)
        #expect(n(ThoughtCounts.due(tag: "a", now: now)) == expected)
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    @Test func storeSaveNotifiesDidSaveFilteredByItsContext() {
        let store = ThoughtStore(context: context, defaultIntervalDays: 7)
        let received = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: nil
        ) { _ in received.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.create(body: "hello #a", now: now)
        #expect(received.value > 0)
    }
}
