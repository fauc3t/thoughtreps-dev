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

    // MARK: Linked thoughts

    /// The most "Linked from" lists; the rest show as a count.
    static let linkedFromLimit = 50

    /// The thoughts with these ids, archived or not, in one fetch. Ids with no thought are missing from the result.
    static func targets(of ids: [UUID], in context: ModelContext) -> [UUID: Thought] {
        guard !ids.isEmpty else { return [:] }
        do {
            let found = try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) }))
            return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            logger.error("Link target fetch failed: \(error)")
            return [:]
        }
    }

    /// The thoughts that link to `id`, archived ones left out, at most `linkedFromLimit`, and how many
    /// there are in all. Sources are the most recently updated first.
    static func linkedFrom(_ id: UUID, in context: ModelContext) -> (thoughts: [Thought], total: Int) {
        let link = BlockKind.thoughtLink.rawValue
        let predicate = #Predicate<Block> {
            $0.kindRaw == link && $0.linkedThoughtID == id && !($0.thought?.isArchived ?? true)
        }
        do {
            let total = try context.fetchCount(FetchDescriptor<Block>(predicate: predicate))
            var descriptor = FetchDescriptor<Block>(predicate: predicate)
            descriptor.sortBy = [SortDescriptor(\.thought?.updatedAt, order: .reverse), SortDescriptor(\.id)]
            descriptor.fetchLimit = linkedFromLimit
            return (try context.fetch(descriptor).compactMap(\.thought), total)
        } catch {
            logger.error("Linked-from fetch failed: \(error)")
            return ([], 0)
        }
    }
}
