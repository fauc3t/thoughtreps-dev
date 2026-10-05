import Foundation

/// Plans the daily "thoughts are back" reminders, as pure functions of plain values.
enum ReminderPlanner {
    static let defaultDays = 7

    /// The thought fields that decide whether it counts toward a reminder.
    struct Input: Equatable {
        var nextDueAt: Date
        var isPinned: Bool
        var isArchived: Bool
    }

    struct Entry: Equatable {
        var fireDate: Date
        var count: Int
    }

    /// One entry per day at `hour:minute`, covering the next `days` fire times. Today is
    /// included only if that time is still ahead of `now`; otherwise planning starts tomorrow.
    /// Days with nothing due are omitted.
    ///
    /// A thought counts on a day if it is unarchived, unpinned (pinned thoughts never count)
    /// and due by that day's fire time, so overdue thoughts count on every day until opened.
    static func plan(
        thoughts: [Input],
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar = .current,
        days: Int = defaultDays
    ) -> [Entry] {
        let counted = thoughts.filter { !$0.isArchived && !$0.isPinned }
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
            let count = counted.filter { $0.nextDueAt <= fire }.count
            if count > 0 { entries.append(Entry(fireDate: fire, count: count)) }
        }
        return entries
    }

    /// Pending reminder ids (those starting with `prefix`) that aren't in `keep`.
    static func staleIdentifiers(pending: [String], keep: Set<String>, prefix: String) -> [String] {
        pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) }
    }

    static func message(count: Int) -> String {
        count == 1 ? "1 thought is back today" : "\(count) thoughts are back today"
    }
}
