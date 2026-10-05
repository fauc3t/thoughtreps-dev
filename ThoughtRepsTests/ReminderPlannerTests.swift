import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

struct ReminderPlannerTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private struct Input {
        var nextDueAt: Date
        var isPinned: Bool
        var isArchived: Bool
    }

    private func input(due: Date, pinned: Bool = false, archived: Bool = false) -> Input {
        .init(nextDueAt: due, isPinned: pinned, isArchived: archived)
    }

    private func counter(_ thoughts: [Input]) -> (Date) -> Int {
        { fire in thoughts.filter { !$0.isArchived && !$0.isPinned && $0.nextDueAt <= fire }.count }
    }

    private func fullPlan(_ thoughts: [Input], now: Date) -> [ReminderPlanner.Entry] {
        ReminderPlanner.plan(hour: 8, minute: 0, now: now, calendar: calendar, count: counter(thoughts))
    }

    private func plan(_ thoughts: [Input], now: Date) -> [ReminderPlanner.Entry] {
        fullPlan(thoughts, now: now).filter { $0.kind == .daily }
    }

    private func followUps(_ thoughts: [Input], now: Date) -> [ReminderPlanner.Entry] {
        fullPlan(thoughts, now: now).filter { $0.kind == .followUp }
    }

    @Test func includesTodayWhenReminderTimeIsAhead() {
        let entries = plan([input(due: date(2026, 3, 1))], now: date(2026, 3, 10, 7, 0))
        #expect(entries.count == 7)
        #expect(entries.first?.fireDate == date(2026, 3, 10, 8, 0))
    }

    @Test func startsTomorrowWhenReminderTimeHasPassed() {
        let entries = plan([input(due: date(2026, 3, 1))], now: date(2026, 3, 10, 9, 0))
        #expect(entries.first?.fireDate == date(2026, 3, 11, 8, 0))
        #expect(entries.count == 7)
        #expect(entries.last?.fireDate == date(2026, 3, 17, 8, 0))
    }

    @Test func skipsDaysWithNothingDue() {
        let entries = plan([input(due: date(2026, 3, 12, 12, 0))], now: date(2026, 3, 10, 7, 0))
        #expect(entries.first?.fireDate == date(2026, 3, 13, 8, 0))
        #expect(entries.count == 4)
    }

    @Test func countsAccumulateAsThoughtsComeDue() {
        let thoughts = [
            input(due: date(2026, 3, 11, 8, 0)),
            input(due: date(2026, 3, 12, 7, 59)),
            input(due: date(2026, 3, 12, 8, 1)),
        ]
        let entries = plan(thoughts, now: date(2026, 3, 10, 7, 0))
        #expect(entries.map(\.count) == [1, 2, 3, 3, 3, 3])
        #expect(entries.first?.fireDate == date(2026, 3, 11, 8, 0))
    }

    @Test func excludesPinnedAndArchived() {
        let thoughts = [
            input(due: date(2026, 3, 1), pinned: true),
            input(due: date(2026, 3, 1), archived: true),
            input(due: date(2026, 3, 1)),
        ]
        #expect(plan(thoughts, now: date(2026, 3, 10, 7, 0)).allSatisfy { $0.count == 1 })
        #expect(plan(Array(thoughts.prefix(2)), now: date(2026, 3, 10, 7, 0)).isEmpty)
    }

    @Test func includesOverdueThoughts() {
        let entries = plan([input(due: date(2025, 1, 1))], now: date(2026, 3, 10, 7, 0))
        #expect(entries.first?.count == 1)
    }

    @Test func keepsReminderTimeAcrossDST() {
        // US spring forward: 2026-03-08, 02:00 -> 03:00.
        let entries = plan([input(due: date(2026, 3, 1))], now: date(2026, 3, 6, 9, 0))
        #expect(entries.map(\.fireDate) == (7...13).map { date(2026, 3, $0, 8, 0) })
        let hours = entries.map { calendar.component(.hour, from: $0.fireDate) }
        #expect(hours.allSatisfy { $0 == 8 })
    }

    @Test func messageText() {
        #expect(ReminderPlanner.message(count: 1) == "1 thought is back today")
        #expect(ReminderPlanner.message(count: 3) == "3 thoughts are back today")
    }

    @Test func springForwardGapDoesNotSkipTheDay() {
        let entries = ReminderPlanner.plan(
            hour: 2, minute: 30, now: date(2026, 3, 7, 12, 0), calendar: calendar, followUpOffsets: [],
            count: counter([input(due: date(2026, 3, 1))])
        )
        #expect(entries.count == 7)
        let days = entries.map { calendar.component(.day, from: $0.fireDate) }
        #expect(days == [8, 9, 10, 11, 12, 13, 14])
    }

    @Test func staleIdentifiersKeepsNewAndIgnoresOthers() {
        let stale = ReminderPlanner.staleIdentifiers(
            pending: ["r.1", "r.2", "r.3", "other.4"], keep: ["r.2"], prefix: "r."
        )
        #expect(stale == ["r.1", "r.3"])
    }

    @Test func neverReturnsMoreThanTenEntriesWithUniqueIncreasingFireDates() {
        let overdue = (0..<50).map { input(due: date(2026, 1, 1).addingTimeInterval(Double($0) * 3600)) }
        for now in [date(2026, 3, 10, 7, 0), date(2026, 3, 10, 9, 0)] {
            let entries = fullPlan(overdue, now: now)
            #expect(entries.count == 10)
            #expect(entries.filter { $0.kind == .daily }.count == 7)
            #expect(Set(entries.map(\.fireDate)).count == entries.count)
            #expect(entries.map(\.fireDate) == entries.map(\.fireDate).sorted())
        }
    }

    @Test func followUpsLandOnDays14_30_90AtReminderTime() {
        let thoughts = [input(due: date(2026, 3, 1))]
        for now in [date(2026, 3, 10, 7, 0), date(2026, 3, 10, 9, 0)] {
            let entries = followUps(thoughts, now: now)
            #expect(entries.map(\.fireDate) == [date(2026, 3, 24, 8, 0), date(2026, 4, 9, 8, 0), date(2026, 6, 8, 8, 0)])
        }
    }

    @Test func omitsFollowUpWithNothingDue() {
        let entries = followUps([input(due: date(2026, 4, 20, 12, 0))], now: date(2026, 3, 10, 7, 0))
        #expect(entries.map(\.fireDate) == [date(2026, 6, 8, 8, 0)])
        #expect(followUps([], now: date(2026, 3, 10, 7, 0)).isEmpty)
    }

    @Test func followUpCountsIncludeThoughtsDueAfterTheDailyWindow() {
        let thoughts = [
            input(due: date(2026, 3, 1)),
            input(due: date(2026, 3, 20)),
            input(due: date(2026, 4, 5)),
            input(due: date(2026, 5, 1)),
        ]
        let entries = followUps(thoughts, now: date(2026, 3, 10, 7, 0))
        #expect(entries.map(\.count) == [2, 3, 4])
    }

    @Test func followUpsExcludePinnedAndArchived() {
        let thoughts = [
            input(due: date(2026, 3, 1), pinned: true),
            input(due: date(2026, 3, 1), archived: true),
            input(due: date(2026, 3, 1)),
        ]
        #expect(followUps(thoughts, now: date(2026, 3, 10, 7, 0)).allSatisfy { $0.count == 1 })
        #expect(followUps(Array(thoughts.prefix(2)), now: date(2026, 3, 10, 7, 0)).isEmpty)
    }

    @Test func followUpMessageText() {
        #expect(ReminderPlanner.message(count: 1, kind: .followUp) == "1 thought is waiting for you")
        #expect(ReminderPlanner.message(count: 4, kind: .followUp) == "4 thoughts are waiting for you")
        #expect(ReminderPlanner.message(count: 4, kind: .daily) == "4 thoughts are back today")
    }

    @Test func followUpKeepsReminderTimeAcrossDST() {
        // Day 14 from 2026-03-01 is 2026-03-15, after the 2026-03-08 spring forward.
        let entries = followUps([input(due: date(2026, 2, 1))], now: date(2026, 3, 1, 7, 0))
        #expect(entries.first?.fireDate == date(2026, 3, 15, 8, 0))
        #expect(entries.allSatisfy { calendar.component(.hour, from: $0.fireDate) == 8 })
        #expect(entries.last?.fireDate == date(2026, 5, 30, 8, 0))
    }

    @Test func followUpInsideSpringForwardGapStillFires() throws {
        let entries = ReminderPlanner.plan(
            hour: 2, minute: 30, now: date(2026, 2, 22, 12, 0), calendar: calendar,
            count: counter([input(due: date(2026, 2, 1))])
        )
        let followUp = try #require(entries.first { $0.kind == .followUp })
        let parts = calendar.dateComponents([.year, .month, .day], from: followUp.fireDate)
        #expect(parts == DateComponents(year: 2026, month: 3, day: 8))
    }

    @MainActor
    @Test func countedPredicateExcludesPinnedAndArchivedAndIncludesOverdue() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let fire = date(2026, 3, 10, 8, 0)
        func add(due: Date, pinned: Bool = false, archived: Bool = false) {
            let thought = Thought(body: "x", nextDueAt: due)
            thought.isPinned = pinned
            thought.isArchived = archived
            context.insert(thought)
        }
        add(due: date(2025, 1, 1))
        add(due: date(2026, 3, 10, 8, 0))
        add(due: date(2026, 3, 10, 8, 1))
        add(due: date(2025, 1, 1), pinned: true)
        add(due: date(2025, 1, 1), archived: true)
        try context.save()
        let count = try context.fetchCount(FetchDescriptor<Thought>(predicate: ReminderPlanner.countedPredicate(dueBy: fire)))
        #expect(count == 2)
    }
}
