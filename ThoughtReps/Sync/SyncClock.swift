import Foundation

/// The skew-safe change clock (a lite hybrid logical clock). `ThoughtStore` remembers the highest clock it has
/// seen, in remote records and in its own stamps, and every change clock it writes is
/// `max(now + serverOffset, highestSeen + 1 ms)`: a device whose wall clock runs behind still wins with an edit made
/// after it saw the other's, and a stamp is never lower than an earlier one, even when the offset changes.
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

    /// How far the server's clock is ahead of this device's (`ServerClockOffset`); zero until a server has answered.
    var serverOffset: TimeInterval {
        defaults.double(forKey: ServerClockOffset.key)
    }

    /// `now` moved onto the server's clock, then raised above everything seen. Only the change-clock stamp uses the offset.
    func stamp(_ now: Date) -> Date {
        let adjusted = now.addingTimeInterval(serverOffset)
        let seen = highestSeen
        return seen == .distantPast ? adjusted : max(adjusted, seen.addingTimeInterval(Self.step))
    }

    func observe(_ clock: Date) {
        if clock > highestSeen { defaults.set(clock.timeIntervalSinceReferenceDate, forKey: Self.key) }
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: ServerClockOffset.key)
        defaults.removeObject(forKey: ServerClockOffset.pendingKey)
    }
}

/// Estimates how far the server's clock is from this device's, from the `serverTime` every response carries. The sample
/// is the server's time minus the midpoint of the request's round trip. Nothing is adopted from one sample: the first
/// adoption needs `agreeingSamples` in a row within `agreement` of each other, later samples are smoothed, and one that
/// differs from the estimate by more than `jump` is only taken once `agreeingSamples` in a row agree on it (a real clock
/// change). Stored beside `highestSeen`; `SyncClock.stamp` adds it.
struct ServerClockOffset: @unchecked Sendable {  // UserDefaults is thread-safe; the transport reads and writes it off the main actor.
    static let key = "syncServerClockOffset"
    /// A sample this far off is a wrong clock (or a broken response), not skew worth correcting.
    static let maxOffset: TimeInterval = 86_400
    /// Slower round trips say little about the midpoint.
    static let maxRoundTrip: TimeInterval = 2
    /// Weight of a new sample against the stored estimate.
    static let weight = 0.3
    static let agreeingSamples = 3
    static let agreement: TimeInterval = 2
    static let jump: TimeInterval = 60
    static let pendingKey = "syncServerClockOffsetPending"

    enum Outcome: Equatable {
        case applied(offset: TimeInterval)
        case slowResponse
        case implausible(TimeInterval)
        /// Kept, waiting for more samples that agree.
        case pending
    }

    var defaults: UserDefaults

    var current: TimeInterval { defaults.double(forKey: Self.key) }

    /// `bestRoundTrip` is the quickest round trip seen so far (nil for the first); a response more than three times it, or
    /// slower than `maxRoundTrip`, is ignored.
    @discardableResult
    func observe(sentAt: Date, receivedAt: Date, serverTimeMs: Int64, bestRoundTrip: TimeInterval?) -> Outcome {
        let roundTrip = receivedAt.timeIntervalSince(sentAt)
        guard roundTrip >= 0, roundTrip <= Self.maxRoundTrip, roundTrip <= max(3 * (bestRoundTrip ?? roundTrip), 0.1) else { return .slowResponse }
        let midpoint = sentAt.addingTimeInterval(roundTrip / 2)
        let sample = Double(serverTimeMs) / 1000 - midpoint.timeIntervalSince1970
        guard abs(sample) <= Self.maxOffset else { return .implausible(sample) }
        let known = defaults.object(forKey: Self.key) != nil
        if known, abs(sample - current) <= Self.jump {
            defaults.removeObject(forKey: Self.pendingKey)
            let smoothed = current * (1 - Self.weight) + sample * Self.weight
            defaults.set(smoothed, forKey: Self.key)
            return .applied(offset: smoothed)
        }
        let pending = Array(((defaults.array(forKey: Self.pendingKey) as? [Double] ?? []) + [sample]).suffix(Self.agreeingSamples))
        guard pending.count == Self.agreeingSamples, let low = pending.min(), let high = pending.max(), high - low <= Self.agreement else {
            defaults.set(pending, forKey: Self.pendingKey)
            return .pending
        }
        defaults.removeObject(forKey: Self.pendingKey)
        // Stamps written before this used the raw clock: floor later ones above it.
        SyncClock(defaults: defaults).observe(receivedAt)
        let adopted = pending.reduce(0, +) / Double(pending.count)
        defaults.set(adopted, forKey: Self.key)
        return .applied(offset: adopted)
    }
}
