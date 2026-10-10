import Foundation

/// How a thought comes back after you see it.
enum IntervalMode: String, CaseIterable, Identifiable {
    /// Same interval every time (the v1 behavior).
    case fixed
    /// Learn mode: opening a thought never moves its due date. You rate it instead
    /// (`Scheduler.afterReview`), and the gap grows after each "Got it".
    case learn

    var id: String { rawValue }
}
