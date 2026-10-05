import Foundation
import SwiftData

/// Plans the daily "thoughts are back" reminders and the sparse follow-ups after them.
/// `plan` is pure; all store access goes through its injected `count`.
enum ReminderPlanner {
    static let defaultDays = 7
    /// Calendar days after today (offsets from `startOfDay(now)`) for the follow-up reminders.
    static let followUpDayOffsets = [14, 30, 90]

    enum Kind: Equatable {
        case daily
        case followUp
    }

    struct Entry: Equatable {
        var fireDate: Date
        var count: Int
        var kind: Kind = .daily
    }

    /// Thoughts that count toward a reminder firing at `fireDate`: unarchived, unpinned (pinned
    /// thoughts never count) and due by then, so overdue thoughts count until opened.
    static func countedPredicate(dueBy fireDate: Date) -> Predicate<Thought> {
        #Predicate<Thought> { !$0.isArchived && !$0.isPinned && $0.nextDueAt <= fireDate }
    }

    /// One entry per day at `hour:minute`, covering the next `days` fire times. Today is
    /// included only if that time is still ahead of `now`; otherwise planning starts tomorrow.
    /// Then one follow-up at the same time on each of `followUpOffsets` days after today.
    /// `count` gives the number of counted thoughts for a fire date; entries with 0 are omitted.
    static func plan(
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar = .current,
        days: Int = defaultDays,
        followUpOffsets: [Int] = followUpDayOffsets,
        count: (Date) throws -> Int
    ) rethrows -> [Entry] {
        let today = calendar.startOfDay(for: now)
        var entries: [Entry] = []
        var fireTimes = 0
        var offset = 0
        while fireTimes < days, offset <= days {
            defer { offset += 1 }
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now
            else { continue }
            fireTimes += 1
            let n = try count(fire)
            if n > 0 { entries.append(Entry(fireDate: fire, count: n)) }
        }
        for offset in followUpOffsets {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now
            else { continue }
            let n = try count(fire)
            if n > 0 { entries.append(Entry(fireDate: fire, count: n, kind: .followUp)) }
        }
        return entries
    }

    /// Pending reminder ids (those starting with `prefix`) that aren't in `keep`.
    static func staleIdentifiers(pending: [String], keep: Set<String>, prefix: String) -> [String] {
        pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) }
    }

    static func message(count: Int, kind: Kind = .daily) -> String {
        switch kind {
        case .daily: count == 1 ? "1 thought is back today" : "\(count) thoughts are back today"
        case .followUp: count == 1 ? "1 thought is waiting for you" : "\(count) thoughts are waiting for you"
        }
    }
}
