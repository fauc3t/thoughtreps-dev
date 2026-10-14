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

/// The default timeline's row order, frozen at its snapshot. Rows load sorted by `nextDueAt`, but opening
/// a thought requeues it, which would move its row while you're still on the list. So the order seen at
/// the snapshot is kept until the next one; thoughts that join later go after, in their loaded order.
/// Only the default timeline (pinned, due, viewed since the snapshot) is frozen: it is bounded, while
/// "show all" lists every thought and is shown as loaded. Pinned thoughts are ordered by pin time
/// (`pinnedSorted`), not `nextDueAt`, in both modes, so opening one never moves it.
enum TimelineOrder {
    /// Ranks plus the snapshot they were taken for.
    struct Frozen {
        var snapshot: Date?
        var ranks: [UUID: Int] = [:]
    }

    /// Extends `frozen` with `thoughts`, or rebuilds it from them when it was taken for another snapshot
    /// (e.g. from rows the previous query had loaded).
    static func refreshed(_ frozen: Frozen, with thoughts: [Thought], snapshot: Date) -> Frozen {
        if frozen.snapshot == snapshot {
            return Frozen(snapshot: snapshot, ranks: ranks(thoughts, extending: frozen.ranks))
        }
        return Frozen(snapshot: snapshot, ranks: ranks(thoughts))
    }

    /// `thoughts`' positions, keeping every rank already in `existing` and appending new ids after them.
    static func ranks(_ thoughts: [Thought], extending existing: [UUID: Int] = [:]) -> [UUID: Int] {
        var ranks = existing
        var next = (existing.values.max() ?? -1) + 1
        for thought in thoughts where ranks[thought.id] == nil {
            ranks[thought.id] = next
            next += 1
        }
        return ranks
    }

    static func sorted(_ thoughts: [Thought], by ranks: [UUID: Int]) -> [Thought] {
        thoughts.enumerated().sorted { a, b in
            let rankA = ranks[a.element.id] ?? Int.max
            let rankB = ranks[b.element.id] ?? Int.max
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Pinned thoughts by when they were pinned, oldest first. `stateChangedAt` isn't touched by opening.
    static func pinnedSorted(_ thoughts: [Thought]) -> [Thought] {
        thoughts.sorted { a, b in
            if a.stateChangedAt != b.stateChangedAt { return a.stateChangedAt < b.stateChangedAt }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
