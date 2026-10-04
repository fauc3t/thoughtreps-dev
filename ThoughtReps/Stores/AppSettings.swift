import Foundation

/// UserDefaults keys and defaults. Views read these with `@AppStorage(AppSettings.Key...)`.
enum AppSettings {
    enum Key {
        static let defaultIntervalDays = "defaultIntervalDays"
        static let didSeedSampleData = "didSeedSampleData"
    }

    static var defaultIntervalDays: Int {
        let stored = UserDefaults.standard.integer(forKey: Key.defaultIntervalDays)
        return stored > 0 ? stored : Scheduler.defaultIntervalDays
    }
}
