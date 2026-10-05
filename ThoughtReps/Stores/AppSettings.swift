import Foundation

/// UserDefaults keys and defaults. Views read these with `@AppStorage(AppSettings.Key...)`.
enum AppSettings {
    enum Key {
        static let defaultIntervalDays = "defaultIntervalDays"
        static let didSeedSampleData = "didSeedSampleData"
        static let reminderEnabled = "reminderEnabled"
        static let reminderMinutes = "reminderMinutes"
    }

    static let defaultReminderMinutes = 8 * 60

    static var defaultIntervalDays: Int {
        let stored = UserDefaults.standard.integer(forKey: Key.defaultIntervalDays)
        return stored > 0 ? stored : Scheduler.defaultIntervalDays
    }

    static var reminderEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.reminderEnabled)
    }

    /// Reminder time as minutes past midnight.
    static var reminderMinutes: Int {
        guard let stored = UserDefaults.standard.object(forKey: Key.reminderMinutes) as? Int,
              (0..<1440).contains(stored)
        else { return defaultReminderMinutes }
        return stored
    }
}
