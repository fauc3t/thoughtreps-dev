import Foundation

/// Counts due opens and decides when to ask for an App Store rating, once ever.
struct RatingPrompt {
    static let dueOpensNeeded = 10

    var defaults: UserDefaults = .standard

    var dueOpenCount: Int { defaults.integer(forKey: AppSettings.Key.ratingDueOpenCount) }
    var isPending: Bool { defaults.bool(forKey: AppSettings.Key.ratingPromptPending) }
    var wasAsked: Bool { defaults.bool(forKey: AppSettings.Key.ratingPromptAsked) }

    func recordDueOpen() {
        guard !wasAsked else { return }
        let count = dueOpenCount + 1
        defaults.set(count, forKey: AppSettings.Key.ratingDueOpenCount)
        if count >= Self.dueOpensNeeded {
            defaults.set(true, forKey: AppSettings.Key.ratingPromptPending)
        }
    }

    /// Call right after requesting the review.
    func markAsked() {
        defaults.set(true, forKey: AppSettings.Key.ratingPromptAsked)
        defaults.set(false, forKey: AppSettings.Key.ratingPromptPending)
    }
}
