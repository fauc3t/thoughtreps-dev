import Foundation
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

    private func input(due: Date, pinned: Bool = false, archived: Bool = false) -> ReminderPlanner.Input {
        .init(nextDueAt: due, isPinned: pinned, isArchived: archived)
    }

    private func plan(_ thoughts: [ReminderPlanner.Input], now: Date) -> [ReminderPlanner.Entry] {
        ReminderPlanner.plan(thoughts: thoughts, hour: 8, minute: 0, now: now, calendar: calendar)
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
            thoughts: [input(due: date(2026, 3, 1))], hour: 2, minute: 30,
            now: date(2026, 3, 7, 12, 0), calendar: calendar
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

    @Test func neverReturnsMoreThanDaysEntriesWithUniqueFireDates() {
        let overdue = (0..<50).map { input(due: date(2026, 1, 1).addingTimeInterval(Double($0) * 3600)) }
        for now in [date(2026, 3, 10, 7, 0), date(2026, 3, 10, 9, 0)] {
            let entries = ReminderPlanner.plan(thoughts: overdue, hour: 8, minute: 0, now: now, calendar: calendar, days: 7)
            #expect(entries.count <= 7)
            #expect(Set(entries.map(\.fireDate)).count == entries.count)
        }
    }
}
