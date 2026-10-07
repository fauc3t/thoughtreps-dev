import Foundation
import UserNotifications

/// Decides whether to offer turning on daily reminders, once ever.
struct ReminderPrompt {
    var defaults: UserDefaults = .standard

    var wasAsked: Bool { defaults.bool(forKey: AppSettings.Key.reminderPromptAsked) }

    /// Only while the OS has not been asked yet and the user hasn't already turned reminders on.
    func shouldOffer(status: UNAuthorizationStatus) -> Bool {
        !wasAsked && !defaults.bool(forKey: AppSettings.Key.reminderEnabled) && status == .notDetermined
    }

    func enableReminders() {
        defaults.set(true, forKey: AppSettings.Key.reminderEnabled)
    }

    /// Call when the prompt is shown.
    func markAsked() {
        defaults.set(true, forKey: AppSettings.Key.reminderPromptAsked)
    }
}
