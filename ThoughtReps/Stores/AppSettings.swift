import Foundation

/// UserDefaults keys and defaults. Views read these with `@AppStorage(AppSettings.Key...)`.
enum AppSettings {
    enum Key {
        static let defaultIntervalDays = "defaultIntervalDays"
        static let didSeedSampleData = "didSeedSampleData"
        static let reminderEnabled = "reminderEnabled"
        static let reminderMinutes = "reminderMinutes"
        static let feedbackEmail = "feedbackEmail"
        static let ratingDueOpenCount = "ratingDueOpenCount"
        static let ratingPromptPending = "ratingPromptPending"
        static let ratingPromptAsked = "ratingPromptAsked"
        static let reminderPromptAsked = "reminderPromptAsked"
        static let thoughtFont = "thoughtFont"
    }

    static let defaultReminderMinutes = 8 * 60

    static var defaultIntervalDays: Int {
        let stored = UserDefaults.standard.integer(forKey: Key.defaultIntervalDays)
        return stored > 0 ? stored : Scheduler.defaultIntervalDays
    }

    static var thoughtFont: ThoughtFont {
        UserDefaults.standard.string(forKey: Key.thoughtFont).flatMap(ThoughtFont.init) ?? .paperMono
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

/// The typeface for thought text (the body, previews, snippets and the editor). Titles and
/// headings stay Archivo either way.
enum ThoughtFont: String, CaseIterable, Identifiable {
    case paperMono
    case system

    var id: Self { self }

    var label: String {
        switch self {
        case .paperMono: "Paper Mono"
        case .system: "System"
        }
    }

    /// Paper Mono sets wider and taller than the system font, so it runs a little smaller to match.
    static let monoScale: CGFloat = 0.88
}
