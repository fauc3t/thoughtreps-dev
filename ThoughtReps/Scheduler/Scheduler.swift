import Foundation

/// The resurfacing rules, as pure functions of plain values.
///
/// Nothing here touches SwiftData or the clock: callers pass `now` (and a calendar),
/// which keeps the rules unit-testable. `Thought+Scheduling` applies them to models.
enum Scheduler {
    static let defaultIntervalDays = 7
    static let maxIntervalDays = 365
    static let learnGrowthFactor = 1.7

    /// The schedule fields that a view or snooze changes.
    struct State: Equatable {
        var nextDueAt: Date
        var lastViewedAt: Date?
        var viewCount: Int
        /// Per-thought override; `nil` = use the default.
        var intervalDays: Int?
    }

    // MARK: Queries

    static func isDue(nextDueAt: Date, now: Date) -> Bool {
        nextDueAt <= now
    }

    /// Whether a thought belongs on the main timeline at `now`.
    ///
    /// `now` is the timeline's snapshot (when the screen last appeared), so a thought
    /// viewed since then (`lastViewedAt >= now`) stays listed until you come back,
    /// rather than vanishing while you're reading it.
    static func isOnTimeline(
        isPinned: Bool,
        isArchived: Bool,
        nextDueAt: Date,
        lastViewedAt: Date? = nil,
        now: Date
    ) -> Bool {
        guard !isArchived else { return false }
        if isPinned || isDue(nextDueAt: nextDueAt, now: now) { return true }
        if let lastViewedAt, lastViewedAt >= now { return true }
        return false
    }

    /// Re-anchors the due date after an interval change: the new interval counts from
    /// the last view, or from creation if the thought has never been viewed.
    static func reanchoredDue(
        createdAt: Date,
        lastViewedAt: Date?,
        intervalDays: Int,
        calendar: Calendar = .current
    ) -> Date {
        adding(days: clamp(intervalDays), to: lastViewedAt ?? createdAt, calendar: calendar)
    }

    // MARK: Transitions

    /// Due date for a brand-new thought.
    static func firstDue(createdAt: Date, intervalDays: Int, calendar: Calendar = .current) -> Date {
        adding(days: clamp(intervalDays), to: createdAt, calendar: calendar)
    }

    /// Applies a view: records it. In `.fixed` mode it also pushes the due date out by the
    /// interval; in `.learn` mode the due date stays, since only a review moves it.
    static func afterView(
        _ state: State,
        mode: IntervalMode,
        defaultIntervalDays: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> State {
        var next = state
        next.lastViewedAt = now
        next.viewCount = state.viewCount + 1
        if mode == .fixed {
            let interval = clamp(state.intervalDays ?? defaultIntervalDays)
            next.nextDueAt = adding(days: interval, to: now, calendar: calendar)
        }
        return next
    }

    /// The gap after "Got it": the base interval the first time, then the last gap times
    /// `learnGrowthFactor` (at least one day longer), capped at `maxIntervalDays`.
    static func learnGapAfterGotIt(lastGapDays: Int?, baseIntervalDays: Int) -> Int {
        guard let lastGapDays else { return clamp(baseIntervalDays) }
        let grown = Int((Double(lastGapDays) * learnGrowthFactor).rounded())
        return clamp(max(grown, lastGapDays + 1))
    }

    /// The Learn fields after a rating. "Got it" grows the gap; "Again" comes back tomorrow
    /// and forgets the gap.
    static func afterReview(
        gotIt: Bool,
        lastGapDays: Int?,
        baseIntervalDays: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> (nextDueAt: Date, learnIntervalDays: Int?) {
        if gotIt {
            let gap = learnGapAfterGotIt(lastGapDays: lastGapDays, baseIntervalDays: baseIntervalDays)
            return (adding(days: gap, to: now, calendar: calendar), gap)
        }
        return (adding(days: 1, to: now, calendar: calendar), nil)
    }

    /// First review of a thought that just turned Learn mode on.
    static func learnStartDue(now: Date, calendar: Calendar = .current) -> Date {
        adding(days: 1, to: now, calendar: calendar)
    }

    /// Pushes the due date `days` from now without counting a view.
    static func snoozed(days: Int, now: Date, calendar: Calendar = .current) -> Date {
        adding(days: clamp(days), to: now, calendar: calendar)
    }

    /// Restoring from the archive makes a thought due immediately.
    static func restoredDue(now: Date) -> Date {
        now
    }

    // MARK: Helpers

    static func clamp(_ days: Int) -> Int {
        min(max(days, 1), maxIntervalDays)
    }

    /// Calendar-day arithmetic, so "7 days" lands at the same clock time across DST changes.
    static func adding(days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }
}
