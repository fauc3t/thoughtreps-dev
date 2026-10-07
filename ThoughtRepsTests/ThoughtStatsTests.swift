import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("ThoughtStats")
struct ThoughtStatsTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let calendar: Calendar
    /// Wednesday 2026-10-14 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_979_200)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        self.calendar = calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func thought(created: Date? = nil, views: Int = 0, archived: Bool = false) -> Thought {
        let thought = Thought(body: "t", createdAt: created ?? now, nextDueAt: now)
        thought.viewCount = views
        thought.isArchived = archived
        context.insert(thought)
        return thought
    }

    private func snapshot() throws -> ThoughtStats.Snapshot {
        try context.save()
        return ThoughtStats.compute(container: container, now: now, calendar: calendar)
    }

    private func mostRevisited() throws -> [Thought] {
        try context.save()
        return try context.fetch(ThoughtStats.mostRevisited)
    }

    @Test func emptyStore() throws {
        let stats = try snapshot()
        #expect(stats.total == 0)
        #expect(stats.totalViews == 0)
        #expect(stats.weeks == Array(repeating: 0, count: 52))
    }

    @Test func totalsActiveAndArchived() throws {
        thought()
        thought()
        thought(archived: true)
        let stats = try snapshot()
        #expect(stats.total == 3)
        #expect(stats.active == 2)
        #expect(stats.archived == 1)
    }

    @Test func thisMonthBoundaries() throws {
        thought(created: date(2026, 9, 30, 23))
        thought(created: date(2026, 10, 1, 0))
        thought(created: date(2026, 10, 31, 23))
        thought(created: date(2026, 11, 1, 0))
        let stats = try snapshot()
        #expect(stats.total == 4)
        #expect(stats.thisMonth == 2)
    }

    @Test func seenAtLeastOnceAndViewSum() throws {
        thought(views: 0)
        thought(views: 1)
        thought(views: 4, archived: true)
        let stats = try snapshot()
        #expect(stats.seenAtLeastOnce == 2)
        #expect(stats.totalViews == 5)
    }

    @Test func viewSumCountsOnlySeenThoughts() throws {
        for views in [1, 2, 3, 4, 5] { thought(views: views) }
        for _ in 0..<3 { thought(views: 0) }
        try context.save()
        #expect(ThoughtStats.totalViews(container: container) == 15)
    }

    @Test func mostRevisitedHiddenBelowThreshold() throws {
        thought(views: ThoughtStats.mostRevisitedThreshold - 1)
        #expect(try mostRevisited().isEmpty)
    }

    @Test func mostRevisitedShownAtThreshold() throws {
        let top = thought(views: ThoughtStats.mostRevisitedThreshold)
        thought(views: 3)
        #expect(try mostRevisited().map(\.id) == [top.id])
    }

    @Test func mostRevisitedPicksHighestViewCount() throws {
        thought(views: 10)
        let top = thought(views: 25)
        thought(views: 12)
        #expect(try mostRevisited().map(\.id) == [top.id])
    }

    @Test func mostRevisitedTieGoesToOldest() throws {
        thought(created: date(2026, 9, 2), views: 12)
        let oldest = thought(created: date(2026, 8, 1), views: 12)
        thought(created: date(2026, 9, 20), views: 12)
        #expect(try mostRevisited().map(\.id) == [oldest.id])
    }

    @Test func mostRevisitedExcludesArchived() throws {
        thought(views: 99, archived: true)
        let active = thought(views: 11)
        #expect(try mostRevisited().map(\.id) == [active.id])
    }

    @Test func mostRevisitedHiddenWhenOnlyArchivedQualifies() throws {
        thought(views: 99, archived: true)
        #expect(try mostRevisited().isEmpty)
    }

    @Test func weekBoundariesFollowCalendarFirstWeekday() {
        let sunday = ThoughtStats.weekBoundaries(now: now, calendar: calendar)
        #expect(sunday.count == 53)
        #expect(sunday[51] == date(2026, 10, 11, 0))
        #expect(sunday[52] == date(2026, 10, 18, 0))

        var monday = calendar
        monday.firstWeekday = 2
        let boundaries = ThoughtStats.weekBoundaries(now: now, calendar: monday)
        #expect(boundaries[51] == date(2026, 10, 12, 0))
    }

    @Test func weeklyBucketsIncludeBoundaryWeeksAndArchived() throws {
        let boundaries = ThoughtStats.weekBoundaries(now: now, calendar: calendar)
        thought(created: boundaries[0])
        thought(created: boundaries[0].addingTimeInterval(-1))
        thought(created: boundaries[1].addingTimeInterval(-1))
        thought(created: boundaries[51], archived: true)
        thought(created: now)
        thought(created: boundaries[52])
        let stats = try snapshot()
        #expect(stats.weeks.count == 52)
        #expect(stats.weeks[0] == 2)
        #expect(stats.weeks[51] == 2)
        #expect(stats.weeks[1...50].allSatisfy { $0 == 0 })
        #expect(stats.lastYear == 4)
        #expect(stats.busiestWeek == 2)
    }

    @Test func shadeLevels() {
        #expect(ThoughtStats.level(count: 0, busiest: 8) == 0)
        #expect(ThoughtStats.level(count: 1, busiest: 8) == 1)
        #expect(ThoughtStats.level(count: 4, busiest: 8) == 2)
        #expect(ThoughtStats.level(count: 6, busiest: 8) == 3)
        #expect(ThoughtStats.level(count: 8, busiest: 8) == 4)
        #expect(ThoughtStats.level(count: 5, busiest: 0) == 0)
    }

    @Test(arguments: [
        (0, "0"), (999, "999"), (1_000, "1k"), (1_234, "1.2k"), (1_950, "2k"), (9_960, "10k"),
        (12_345, "12k"), (123_456, "123k"), (999_499, "999k"), (999_500, "1M"), (1_234_567, "1.2M"),
    ])
    func compactCounts(value: Int, expected: String) {
        #expect(ThoughtStats.compactCount(value, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func rhythmLabelSummarizesGrid() {
        var stats = ThoughtStats.Snapshot()
        stats.weeks = Array(repeating: 0, count: 52)
        #expect(StatsView.rhythmLabel(stats) == "Writing rhythm, no thoughts in the last 52 weeks")
        stats.weeks[3] = 9
        stats.weeks[40] = 3
        #expect(StatsView.rhythmLabel(stats) == "Writing rhythm, 12 thoughts in the last 52 weeks, busiest week 9")
    }
}
