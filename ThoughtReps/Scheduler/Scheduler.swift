import Foundation

/// The resurfacing rules, as pure functions of plain values.
///
/// Nothing here touches SwiftData or the clock: callers pass `now` (and a calendar),
/// which keeps the rules unit-testable. `Thought+Scheduling` applies them to models.
enum Scheduler {
    static let defaultIntervalDays = 7
    static let maxIntervalDays = 365

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

    /// Applies a view: records it and pushes the due date out by the interval.
    /// In `.growing` mode the first view keeps the starting interval; each later view
    /// doubles it (capped) and stores it as the override.
    static func afterView(
        _ state: State,
        mode: IntervalMode,
        defaultIntervalDays: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> State {
        var next = state
        let current = clamp(state.intervalDays ?? defaultIntervalDays)
        let interval: Int
        switch mode {
        case .fixed:
            interval = current
        case .growing:
            // The first view keeps the starting interval; later views double it.
            interval = state.viewCount == 0 ? current : clamp(current * 2)
            next.intervalDays = interval
        }
        next.lastViewedAt = now
        next.viewCount = state.viewCount + 1
        next.nextDueAt = adding(days: interval, to: now, calendar: calendar)
        return next
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
