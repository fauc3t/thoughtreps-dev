import Foundation

extension Scheduler {
    /// Whether opening a thought counts toward the rating prompt: it must be due, not pinned, not
    /// archived. Evaluate before the view reschedules the thought.
    static func countsAsDueOpen(isPinned: Bool, isArchived: Bool, nextDueAt: Date, now: Date) -> Bool {
        !isPinned && !isArchived && isDue(nextDueAt: nextDueAt, now: now)
    }
}
