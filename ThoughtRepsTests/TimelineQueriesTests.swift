import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("TimelineQueries")
struct TimelineQueriesTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let snapshot = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    private func thought(
        _ body: String, due: TimeInterval, pinned: Bool = false, archived: Bool = false,
        viewed: TimeInterval? = nil, tag: ThoughtReps.Tag? = nil
    ) -> Thought {
        let thought = Thought(body: body, createdAt: snapshot, nextDueAt: snapshot.addingTimeInterval(due))
        thought.isPinned = pinned
        thought.isArchived = archived
        thought.lastViewedAt = viewed.map { snapshot.addingTimeInterval($0) }
        context.insert(thought)
        if let tag { thought.tags = [tag] }
        return thought
    }

    private func bodies(_ predicate: Predicate<Thought>) throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<Thought>(predicate: predicate)).map(\.body))
    }

    @Test func keptThoughtStaysListedWhateverItsSchedule() throws {
        let later = thought("later", due: 100)
        thought("other later", due: 100)
        let archived = thought("archived", due: -100, archived: true)
        let kept = ThoughtCounts.timeline(.all, showAll: false, snapshot: snapshot, keeping: later.id)
        #expect(try bodies(kept) == ["later"])
        let keptArchived = ThoughtCounts.timeline(.all, showAll: false, snapshot: snapshot, keeping: archived.id)
        #expect(try bodies(keptArchived).isEmpty)
        #expect(try bodies(ThoughtCounts.timeline(.all, showAll: false, snapshot: snapshot)).isEmpty)
    }

    @Test func selectedThoughtResolvesByPrimaryKey() throws {
        let one = thought("one", due: 0)
        thought("two", due: 0)
        try context.save()
        let modelID = one.persistentModelID
        let found = try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.persistentModelID == modelID }))
        #expect(found.map(\.body) == ["one"])
        context.delete(one)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.persistentModelID == modelID })).isEmpty)
    }

    @Test func timelinePredicateMatchesTheSchedulerRule() throws {
        let tag = ThoughtReps.Tag(name: "a", displayName: "a")
        context.insert(tag)
        for pinned in [false, true] {
            for archived in [false, true] {
                for due in [-100.0, 0, 100] {
                    for viewed in [nil, -50.0, 0, 50] as [TimeInterval?] {
                        let label = "p\(pinned) a\(archived) d\(due) v\(String(describing: viewed))"
                        thought(label, due: due, pinned: pinned, archived: archived, viewed: viewed, tag: tag)
                    }
                }
            }
        }
        try context.save()
        let all = try context.fetch(FetchDescriptor<Thought>())
        let expected = Set(all.filter { $0.isOnTimeline(now: snapshot) }.map(\.body))
        #expect(!expected.isEmpty && expected.count < all.count)
        #expect(try bodies(ThoughtCounts.timeline(.all, showAll: false, snapshot: snapshot)) == expected)
        #expect(try bodies(ThoughtCounts.timeline(.tag("a"), showAll: false, snapshot: snapshot)) == expected)
        #expect(try bodies(ThoughtCounts.timeline(.tag("b"), showAll: false, snapshot: snapshot)).isEmpty)
        #expect(try bodies(ThoughtCounts.timeline(.untagged, showAll: false, snapshot: snapshot)).isEmpty)
    }

    @Test func untaggedScopeAndShowAll() throws {
        let tag = ThoughtReps.Tag(name: "a", displayName: "a")
        context.insert(tag)
        thought("tagged due", due: -1, tag: tag)
        thought("bare due", due: -1)
        thought("bare later", due: 500)
        thought("bare archived", due: -1, archived: true)
        try context.save()
        #expect(try bodies(ThoughtCounts.timeline(.untagged, showAll: false, snapshot: snapshot)) == ["bare due"])
        #expect(try bodies(ThoughtCounts.timeline(.untagged, showAll: true, snapshot: snapshot)) == ["bare due", "bare later"])
        #expect(try bodies(ThoughtCounts.timeline(.all, showAll: true, snapshot: snapshot)) == ["tagged due", "bare due", "bare later"])
    }

    @Test func nextUpCountsThoughtsOnTheEarliestDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: snapshot).addingTimeInterval(86_400)
        let offset = day.timeIntervalSince(snapshot)
        thought("a", due: offset + 3_600)
        thought("b", due: offset + 7_200)
        thought("later", due: offset + 3 * 86_400)
        thought("pinned", due: 10, pinned: true)
        thought("archived", due: 20, archived: true)
        try context.save()
        let result = try #require(ThoughtCounts.nextUp(.all, in: context, calendar: calendar))
        #expect(result.next == day.addingTimeInterval(3_600))
        #expect(result.count == 2)
    }

    @Test func nextUpIsNilWithoutUnpinnedThoughts() throws {
        thought("pinned", due: 10, pinned: true)
        try context.save()
        #expect(ThoughtCounts.nextUp(.all, in: context) == nil)
    }

    @Test func orderStaysFrozenWhenAThoughtIsRequeued() throws {
        let first = thought("first", due: -300)
        let second = thought("second", due: -200)
        let third = thought("third", due: -100)
        let ranks = TimelineOrder.ranks([first, second, third])
        first.nextDueAt = snapshot.addingTimeInterval(7 * 86_400) // opened, so requeued
        let reloaded = [second, third, first] // as a nextDueAt sort would now load them
        #expect(TimelineOrder.sorted(reloaded, by: ranks).map(\.body) == ["first", "second", "third"])
    }

    @Test func thoughtsJoiningLaterGoAfterInLoadedOrder() throws {
        let first = thought("first", due: -300)
        let second = thought("second", due: -200)
        let lateA = thought("late a", due: -400)
        let lateB = thought("late b", due: -50)
        let ranks = TimelineOrder.ranks([lateA, first, second, lateB], extending: TimelineOrder.ranks([first, second]))
        #expect(TimelineOrder.sorted([lateA, first, second, lateB], by: ranks).map(\.body) == ["first", "second", "late a", "late b"])
        #expect(TimelineOrder.sorted([lateB, second, lateA, first], by: [:]).map(\.body) == ["late b", "second", "late a", "first"])
    }

    @Test func refreshRebuildsForANewSnapshotAndExtendsForTheSame() throws {
        let old = thought("old", due: -300)
        let first = thought("first", due: -200)
        let second = thought("second", due: -100)
        let stale = TimelineOrder.Frozen(snapshot: nil, ranks: TimelineOrder.ranks([old]))
        let rebuilt = TimelineOrder.refreshed(stale, with: [first, second], snapshot: snapshot)
        #expect(rebuilt.snapshot == snapshot)
        #expect(TimelineOrder.sorted([second, first], by: rebuilt.ranks).map(\.body) == ["first", "second"])
        let extended = TimelineOrder.refreshed(rebuilt, with: [old, second, first], snapshot: snapshot)
        #expect(TimelineOrder.sorted([old, second, first], by: extended.ranks).map(\.body) == ["first", "second", "old"])
    }

    @Test func sameSnapshotRefetchAfterRequeueKeepsFrozenOrder() throws {
        let first = thought("first", due: -300)
        let second = thought("second", due: -200)
        let frozen = TimelineOrder.Frozen(snapshot: snapshot, ranks: TimelineOrder.ranks([first, second]))
        first.nextDueAt = snapshot.addingTimeInterval(7 * 86_400)
        let refreshed = TimelineOrder.refreshed(frozen, with: [second, first], snapshot: snapshot)
        #expect(TimelineOrder.sorted([second, first], by: refreshed.ranks).map(\.body) == ["first", "second"])
    }
}
