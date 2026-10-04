import Foundation

/// How a thought's interval changes each time it is viewed.
enum IntervalMode: String, CaseIterable, Identifiable {
    /// Same interval every time (the v1 behavior).
    case fixed
    /// First view keeps the starting interval; each later view doubles it, up to
    /// `Scheduler.maxIntervalDays`. Not exposed in the UI yet.
    case growing

    var id: String { rawValue }
}
