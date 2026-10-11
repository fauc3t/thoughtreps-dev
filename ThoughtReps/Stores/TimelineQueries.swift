import Foundation
import SwiftData

/// Predicates behind the timeline, so it loads only the thoughts it shows. `snapshot` is the
/// timeline's "now as of last appear"; the rule matches `Scheduler.isOnTimeline` for active thoughts.
extension ThoughtCounts {
    enum Scope: Equatable {
        case all
        case tag(String)
        case untagged
    }

    /// Every active thought in the scope.
    static func active(_ scope: Scope) -> Predicate<Thought> {
        switch scope {
        case .all: return #Predicate<Thought> { !$0.isArchived }
        case .tag(let name): return active(tag: name)
        case .untagged: return untagged
        }
    }

    /// What the timeline lists: pinned, due at `snapshot`, or viewed since `snapshot`; or all active
    /// thoughts in the scope when `showAll`. `keeping` is the thought open in the split view's detail
    /// column, which stays listed whatever its schedule.
    static func timeline(_ scope: Scope, showAll: Bool, snapshot: Date, keeping: UUID? = nil) -> Predicate<Thought> {
        if showAll { return active(scope) }
        let floor = Date.distantPast
        // The nil UUID is never a thought's id, so without a thought to keep nothing extra matches.
        let kept = keeping ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        switch scope {
        case .all:
            return #Predicate<Thought> {
                !$0.isArchived && ($0.isPinned || $0.nextDueAt <= snapshot || ($0.lastViewedAt ?? floor) >= snapshot || $0.id == kept)
            }
        case .tag(let name):
            return #Predicate<Thought> {
                !$0.isArchived && ($0.isPinned || $0.nextDueAt <= snapshot || ($0.lastViewedAt ?? floor) >= snapshot || $0.id == kept)
                    && ($0.tags?.contains { $0.name == name } ?? false)
            }
        case .untagged:
            return #Predicate<Thought> {
                !$0.isArchived && ($0.isPinned || $0.nextDueAt <= snapshot || ($0.lastViewedAt ?? floor) >= snapshot || $0.id == kept)
                    && !($0.tags?.contains { _ in true } ?? false)
            }
        }
    }

    /// Active, unpinned thoughts in the scope due in `[from, before)`.
    static func upcoming(_ scope: Scope, from: Date = .distantPast, before: Date = .distantFuture) -> Predicate<Thought> {
        switch scope {
        case .all:
            return #Predicate<Thought> { !$0.isArchived && !$0.isPinned && $0.nextDueAt >= from && $0.nextDueAt < before }
        case .tag(let name):
            return #Predicate<Thought> {
                !$0.isArchived && !$0.isPinned && $0.nextDueAt >= from && $0.nextDueAt < before
                    && ($0.tags?.contains { $0.name == name } ?? false)
            }
        case .untagged:
            return #Predicate<Thought> {
                !$0.isArchived && !$0.isPinned && $0.nextDueAt >= from && $0.nextDueAt < before
                    && !($0.tags?.contains { _ in true } ?? false)
            }
        }
    }

    /// The earliest due date among the scope's unpinned active thoughts and how many fall on that day.
    static func nextUp(_ scope: Scope, in context: ModelContext, calendar: Calendar = .current) -> (next: Date, count: Int)? {
        var first = FetchDescriptor<Thought>(predicate: upcoming(scope), sortBy: [SortDescriptor(\.nextDueAt)])
        first.fetchLimit = 1
        guard let next = (try? context.fetch(first))?.first?.nextDueAt else { return nil }
        let start = calendar.startOfDay(for: next)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
        return (next, count(upcoming(scope, from: start, before: end), in: context))
    }
}
