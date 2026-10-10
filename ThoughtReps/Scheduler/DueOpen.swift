import Foundation

extension Scheduler {
    /// Whether opening a thought counts toward the rating prompt: it must be due, not pinned, not
    /// archived. Evaluate before the view reschedules the thought. Learn thoughts never count on open;
    /// their due comebacks count when rated (`ThoughtStore.review`).
    static func countsAsDueOpen(isPinned: Bool, isArchived: Bool, nextDueAt: Date, now: Date) -> Bool {
        !isPinned && !isArchived && isDue(nextDueAt: nextDueAt, now: now)
    }
}
