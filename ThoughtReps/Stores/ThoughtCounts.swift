import Foundation
import OSLog
import SwiftData

/// Predicates and `fetchCount` helpers for the counts on the Tags tab and in tag suggestions,
/// so counting never loads thoughts into memory. Tags are matched by `name`, which
/// `ThoughtStore` keeps unique. "Due" is `nextDueAt <= now`, as in `Scheduler.isDue`.
enum ThoughtCounts {
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "counts")

    static func active(tag name: String) -> Predicate<Thought> {
        #Predicate<Thought> { !$0.isArchived && ($0.tags?.contains { $0.name == name } ?? false) }
    }

    static func due(tag name: String, now: Date) -> Predicate<Thought> {
        #Predicate<Thought> {
            !$0.isArchived && $0.nextDueAt <= now && ($0.tags?.contains { $0.name == name } ?? false)
        }
    }

    /// Includes archived thoughts.
    static func any(tag name: String) -> Predicate<Thought> {
        #Predicate<Thought> { $0.tags?.contains { $0.name == name } ?? false }
    }

    /// `tags?.isEmpty` fails at runtime in SwiftData's count request (`tags.@count`), so "no tags"
    /// is "no element satisfies an always-true test".
    static let untagged = #Predicate<Thought> { !$0.isArchived && !($0.tags?.contains { _ in true } ?? false) }

    static func dueUntagged(now: Date) -> Predicate<Thought> {
        #Predicate<Thought> { !$0.isArchived && $0.nextDueAt <= now && !($0.tags?.contains { _ in true } ?? false) }
    }

    /// `limit` stops counting early for existence checks.
    static func count(_ predicate: Predicate<Thought>, in context: ModelContext, limit: Int? = nil) -> Int {
        do {
            var descriptor = FetchDescriptor<Thought>(predicate: predicate)
            descriptor.fetchLimit = limit
            return try context.fetchCount(descriptor)
        } catch {
            logger.error("Count query failed: \(error)")
            return 0
        }
    }
}
