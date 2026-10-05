import Foundation
import OSLog
import SwiftData
import UserNotifications

/// Schedules the daily reminder as local notifications, rebuilt from the store each time.
@MainActor
enum NotificationScheduler {
    static let identifierPrefix = "thoughtreps.reminder."
    /// Test reminders use their own prefix so a reschedule (e.g. on backgrounding) doesn't remove them.
    static let testIdentifierPrefix = "thoughtreps.test-reminder."

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for alert and sound permission; returns whether it was granted.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "notifications")
    private static var inFlight: Task<Void, Never>?
    private static var rerunRequested = false
    private static var latest: (context: ModelContext, now: Date)?

    /// Brings pending reminders in line with the current thoughts and settings. Calls made while
    /// one is running coalesce into a single follow-up run that reads settings fresh, so the last
    /// request always wins. Returns once that run has finished.
    static func reschedule(context: ModelContext, now: Date) async {
        latest = (context, now)
        if let inFlight {
            rerunRequested = true
            await inFlight.value
            return
        }
        let task = Task {
            repeat {
                rerunRequested = false
                if let latest { await performReschedule(context: latest.context, now: latest.now) }
            } while rerunRequested
            inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Sends a reminder as it would read right now, after `delay` seconds, so it can be seen on
    /// the Lock Screen too. Asks for permission first if needed; returns whether it was scheduled.
    static func sendTestReminder(context: ModelContext, now: Date, delay: TimeInterval = 5) async -> Bool {
        guard await requestAuthorization() else { return false }
        let count = (try? context.fetchCount(FetchDescriptor<Thought>(predicate: ReminderPlanner.countedPredicate(dueBy: now)))) ?? 0
        let content = UNMutableNotificationContent()
        content.title = "Thought Reps"
        content.body = ReminderPlanner.message(count: count)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: testIdentifierPrefix + UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            logger.error("Couldn't schedule test reminder: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes stale reminders before adding the planned ones, so pending never exceeds the plan.
    /// Leaves pending reminders untouched if the thoughts can't be counted.
    private static func performReschedule(context: ModelContext, now: Date) async {
        let center = UNUserNotificationCenter.current()
        let status = await authorizationStatus()
        var entries: [ReminderPlanner.Entry] = []
        let calendar = Calendar.current

        if AppSettings.reminderEnabled, status == .authorized || status == .provisional {
            let minutes = AppSettings.reminderMinutes
            do {
                entries = try ReminderPlanner.plan(
                    hour: minutes / 60,
                    minute: minutes % 60,
                    now: now,
                    calendar: calendar
                ) { fireDate in
                    try context.fetchCount(FetchDescriptor<Thought>(predicate: ReminderPlanner.countedPredicate(dueBy: fireDate)))
                }
            } catch {
                logger.error("Reminder reschedule skipped, count failed: \(error.localizedDescription)")
                return
            }
        }

        let planned = entries.map { entry in
            (id: identifierPrefix + String(Int(entry.fireDate.timeIntervalSince1970)), entry: entry)
        }

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: ReminderPlanner.staleIdentifiers(
                pending: pending.map(\.identifier), keep: Set(planned.map(\.id)), prefix: identifierPrefix
            )
        )

        for (identifier, entry) in planned {
            let content = UNMutableNotificationContent()
            content.title = "Thought Reps"
            content.body = ReminderPlanner.message(count: entry.count, kind: entry.kind)
            content.sound = .default
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: entry.fireDate)
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
            } catch {
                logger.error("Couldn't schedule reminder: \(error.localizedDescription)")
            }
        }
    }
}
