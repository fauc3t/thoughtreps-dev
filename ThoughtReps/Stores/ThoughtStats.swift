import Foundation
import OSLog
import SwiftData

/// Read-only numbers for the Stats tab. Everything is a `fetchCount` or a narrow fetch, so no
/// thought is loaded just to be counted; `compute` is meant to run off the main thread.
enum ThoughtStats {
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "stats")

    /// The Most revisited section only appears once a thought has been seen this many times.
    static let mostRevisitedThreshold = 10
    static let weekCount = 52

    struct Snapshot: Sendable, Equatable {
        var total = 0
        var thisMonth = 0
        var seenAtLeastOnce = 0
        var totalViews = 0
        var active = 0
        var archived = 0
        /// Thoughts created per week, oldest first; the last entry is the week containing `now`.
        var weeks: [Int] = []

        var lastYear: Int { weeks.reduce(0, +) }
        var busiestWeek: Int { weeks.max() ?? 0 }
    }

    static func createdBetween(_ start: Date, _ end: Date) -> Predicate<Thought> {
        #Predicate<Thought> { $0.createdAt >= start && $0.createdAt < end }
    }

    static let everything = #Predicate<Thought> { _ in true }
    static let seen = #Predicate<Thought> { $0.viewCount > 0 }
    static let activeThoughts = #Predicate<Thought> { !$0.isArchived }
    static let archivedThoughts = #Predicate<Thought> { $0.isArchived }

    /// Non-archived thoughts at or over the threshold, most viewed first, oldest first on a tie.
    /// Empty when the section should be hidden.
    static var mostRevisited: FetchDescriptor<Thought> {
        let threshold = mostRevisitedThreshold
        var descriptor = FetchDescriptor<Thought>(
            predicate: #Predicate { !$0.isArchived && $0.viewCount >= threshold },
            sortBy: [SortDescriptor(\.viewCount, order: .reverse), SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Start of each of the last `weekCount` weeks, oldest first, plus the end of the last one.
    static func weekBoundaries(now: Date, calendar: Calendar) -> [Date] {
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        let first = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: current.start) ?? current.start
        return (0...weekCount).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: first) }
    }

    /// Shade step for a week's count: 0 for an empty week, otherwise 1...4 scaled to the busiest week.
    static func level(count: Int, busiest: Int) -> Int {
        guard count > 0, busiest > 0 else { return 0 }
        return min(4, max(1, Int((Double(count) / Double(busiest) * 4).rounded(.up))))
    }

    static func compute(container: ModelContainer, now: Date, calendar: Calendar) -> Snapshot {
        let context = ModelContext(container)
        var snapshot = Snapshot()
        snapshot.total = ThoughtCounts.count(everything, in: context)
        snapshot.seenAtLeastOnce = ThoughtCounts.count(seen, in: context)
        snapshot.active = ThoughtCounts.count(activeThoughts, in: context)
        snapshot.archived = ThoughtCounts.count(archivedThoughts, in: context)
        if let month = calendar.dateInterval(of: .month, for: now) {
            snapshot.thisMonth = ThoughtCounts.count(createdBetween(month.start, month.end), in: context)
        }
        let boundaries = weekBoundaries(now: now, calendar: calendar)
        snapshot.weeks = zip(boundaries, boundaries.dropFirst()).map { start, end in
            ThoughtCounts.count(createdBetween(start, end), in: context)
        }
        snapshot.totalViews = totalViews(container: container)
        return snapshot
    }

    /// SwiftData has no aggregate, so this reads `viewCount` alone for the seen thoughts, in one fresh context.
    static func totalViews(container: ModelContainer) -> Int {
        var descriptor = FetchDescriptor<Thought>(predicate: seen)
        descriptor.propertiesToFetch = [\.viewCount]
        do {
            return try ModelContext(container).fetch(descriptor).reduce(0) { $0 + $1.viewCount }
        } catch {
            logger.error("View count query failed: \(error)")
            return 0
        }
    }
}
