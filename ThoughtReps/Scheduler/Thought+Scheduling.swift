import Foundation

extension Thought {
    var scheduleState: Scheduler.State {
        get {
            Scheduler.State(
                nextDueAt: nextDueAt,
                lastViewedAt: lastViewedAt,
                viewCount: viewCount,
                intervalDays: intervalDays
            )
        }
        set {
            nextDueAt = newValue.nextDueAt
            lastViewedAt = newValue.lastViewedAt
            viewCount = newValue.viewCount
            intervalDays = newValue.intervalDays
        }
    }

    func isDue(now: Date) -> Bool {
        Scheduler.isDue(nextDueAt: nextDueAt, now: now)
    }

    func isOnTimeline(now: Date) -> Bool {
        Scheduler.isOnTimeline(
            isPinned: isPinned,
            isArchived: isArchived,
            nextDueAt: nextDueAt,
            lastViewedAt: lastViewedAt,
            now: now
        )
    }

    func applyView(defaultIntervalDays: Int, now: Date) {
        scheduleState = Scheduler.afterView(
            scheduleState,
            mode: intervalMode,
            defaultIntervalDays: defaultIntervalDays,
            now: now
        )
    }

    func applySnooze(days: Int, now: Date) {
        nextDueAt = Scheduler.snoozed(days: days, now: now)
    }
}
