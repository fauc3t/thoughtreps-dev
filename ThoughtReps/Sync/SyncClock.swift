import Foundation

/// The skew-safe change clock (a lite hybrid logical clock). `ThoughtStore` remembers the highest clock it
/// has seen in remote records, and every change clock it writes is `max(now, highestSeen + 1 ms)`, so a
/// device whose wall clock runs behind still wins with an edit made after it saw the other's.
///
/// Only change clocks use it. Due dates, `createdAt`, `lastViewedAt` and the like keep the real `now`.
/// Without sync nothing is ever observed, `highestSeen` stays `distantPast` and `stamp` returns `now`.
struct SyncClock {
    static let key = "syncHighestClockSeen"
    static let step: TimeInterval = 0.001
    /// How far past the local `now` a remote clock may pull `highestSeen`.
    static let maxLead: TimeInterval = 86_400

    var defaults: UserDefaults

    var highestSeen: Date {
        (defaults.object(forKey: Self.key) as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
    }

    func stamp(_ now: Date) -> Date {
        let seen = highestSeen
        return seen == .distantPast ? now : max(now, seen.addingTimeInterval(Self.step))
    }

    func observe(_ clock: Date) {
        if clock > highestSeen { defaults.set(clock.timeIntervalSinceReferenceDate, forKey: Self.key) }
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
