import Foundation
import Testing
@testable import ThoughtReps

@Suite("Scheduler")
struct SchedulerTests {
    /// Fixed calendar and clock so results don't depend on the machine running the tests.
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func newThoughtIsDueAfterItsInterval() {
        let created = date(2026, 10, 4)
        #expect(Scheduler.firstDue(createdAt: created, intervalDays: 7, calendar: calendar) == date(2026, 10, 11))
    }

    @Test func dueExactlyAtNextDueDate() {
        let due = date(2026, 10, 11)
        #expect(Scheduler.isDue(nextDueAt: due, now: due))
        #expect(!Scheduler.isDue(nextDueAt: due, now: due.addingTimeInterval(-1)))
    }

    @Test func timelineShowsPinnedAndDueButNeverArchived() {
        let now = date(2026, 10, 11)
        let future = date(2026, 10, 20)
        let past = date(2026, 10, 1)
        #expect(Scheduler.isOnTimeline(isPinned: false, isArchived: false, nextDueAt: past, now: now))
        #expect(!Scheduler.isOnTimeline(isPinned: false, isArchived: false, nextDueAt: future, now: now))
        #expect(Scheduler.isOnTimeline(isPinned: true, isArchived: false, nextDueAt: future, now: now))
        #expect(!Scheduler.isOnTimeline(isPinned: true, isArchived: true, nextDueAt: past, now: now))
    }

    @Test func thoughtViewedSinceSnapshotStaysListed() {
        let snapshot = date(2026, 10, 11)
        let requeued = date(2026, 10, 18)
        let viewedAfter = snapshot.addingTimeInterval(60)
        let viewedBefore = snapshot.addingTimeInterval(-60)
        #expect(Scheduler.isOnTimeline(isPinned: false, isArchived: false, nextDueAt: requeued, lastViewedAt: viewedAfter, now: snapshot))
        #expect(!Scheduler.isOnTimeline(isPinned: false, isArchived: false, nextDueAt: requeued, lastViewedAt: viewedBefore, now: snapshot))
        #expect(!Scheduler.isOnTimeline(isPinned: false, isArchived: true, nextDueAt: requeued, lastViewedAt: viewedAfter, now: snapshot))
    }

    @Test func reanchorCountsFromLastViewOrCreation() {
        let created = date(2026, 10, 1)
        let viewed = date(2026, 10, 5)
        #expect(Scheduler.reanchoredDue(createdAt: created, lastViewedAt: nil, intervalDays: 1, calendar: calendar) == date(2026, 10, 2))
        #expect(Scheduler.reanchoredDue(createdAt: created, lastViewedAt: viewed, intervalDays: 3, calendar: calendar) == date(2026, 10, 8))
    }

    @Test func viewRequeuesFromNowUsingDefault() {
        let now = date(2026, 10, 13, 20)
        let before = Scheduler.State(nextDueAt: date(2026, 10, 11), lastViewedAt: nil, viewCount: 0, intervalDays: nil)
        let after = Scheduler.afterView(before, mode: .fixed, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(after.nextDueAt == date(2026, 10, 20, 20))
        #expect(after.lastViewedAt == now)
        #expect(after.viewCount == 1)
        #expect(after.intervalDays == nil)
    }

    @Test func viewUsesPerThoughtOverride() {
        let now = date(2026, 10, 4)
        let before = Scheduler.State(nextDueAt: now, lastViewedAt: nil, viewCount: 3, intervalDays: 1)
        let after = Scheduler.afterView(before, mode: .fixed, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(after.nextDueAt == date(2026, 10, 5))
        #expect(after.intervalDays == 1)
    }

    @Test func growingModeDoublesAfterFirstViewAndCaps() {
        let now = date(2026, 10, 4)
        var state = Scheduler.State(nextDueAt: now, lastViewedAt: nil, viewCount: 0, intervalDays: 3)
        state = Scheduler.afterView(state, mode: .growing, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(state.intervalDays == 3)
        state = Scheduler.afterView(state, mode: .growing, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(state.intervalDays == 6)
        #expect(state.nextDueAt == date(2026, 10, 10))

        let big = Scheduler.State(nextDueAt: now, lastViewedAt: nil, viewCount: 5, intervalDays: 300)
        let capped = Scheduler.afterView(big, mode: .growing, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(capped.intervalDays == Scheduler.maxIntervalDays)
    }

    @Test func intervalIsClampedToAtLeastOneDay() {
        let now = date(2026, 10, 4)
        let state = Scheduler.State(nextDueAt: now, lastViewedAt: nil, viewCount: 0, intervalDays: 0)
        let after = Scheduler.afterView(state, mode: .fixed, defaultIntervalDays: 7, now: now, calendar: calendar)
        #expect(after.nextDueAt == date(2026, 10, 5))
    }

    @Test func snoozeCountsFromNow() {
        let now = date(2026, 10, 4, 15)
        #expect(Scheduler.snoozed(days: 1, now: now, calendar: calendar) == date(2026, 10, 5, 15))
    }

    @Test func weekLandsOnSameClockTimeAcrossDST() {
        // US DST ends Nov 1, 2026: 7 calendar days, not 7 × 24 hours.
        let created = date(2026, 10, 28, 9)
        #expect(Scheduler.firstDue(createdAt: created, intervalDays: 7, calendar: calendar) == date(2026, 11, 4, 9))
    }

    @Test func restoreMakesThoughtDueNow() {
        let now = date(2026, 10, 4)
        #expect(Scheduler.restoredDue(now: now) == now)
    }
}
