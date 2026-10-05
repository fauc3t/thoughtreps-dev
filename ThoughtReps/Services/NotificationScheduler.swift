import Foundation
import OSLog
import SwiftData
import UserNotifications

/// Schedules the daily reminder as local notifications, rebuilt from the store each time.
@MainActor
enum NotificationScheduler {
    static let identifierPrefix = "thoughtreps.reminder."

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

    /// Removes stale reminders before adding the planned ones, so pending never exceeds the plan.
    /// Leaves pending reminders untouched if the thoughts can't be read.
    private static func performReschedule(context: ModelContext, now: Date) async {
        let center = UNUserNotificationCenter.current()
        let status = await authorizationStatus()
        var entries: [ReminderPlanner.Entry] = []
        let calendar = Calendar.current

        if AppSettings.reminderEnabled, status == .authorized || status == .provisional {
            let thoughts: [Thought]
            do {
                thoughts = try context.fetch(FetchDescriptor<Thought>())
            } catch {
                logger.error("Reminder reschedule skipped, fetch failed: \(error.localizedDescription)")
                return
            }
            let minutes = AppSettings.reminderMinutes
            entries = ReminderPlanner.plan(
                thoughts: thoughts.map {
                    ReminderPlanner.Input(nextDueAt: $0.nextDueAt, isPinned: $0.isPinned, isArchived: $0.isArchived)
                },
                hour: minutes / 60,
                minute: minutes % 60,
                now: now,
                calendar: calendar
            )
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
            content.body = ReminderPlanner.message(count: entry.count)
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
