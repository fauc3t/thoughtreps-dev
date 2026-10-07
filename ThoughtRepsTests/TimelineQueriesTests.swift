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
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
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
}
