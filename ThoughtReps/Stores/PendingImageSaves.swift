import Foundation

/// Thoughts whose new inline images were saved ahead of the body edit that references them, and
/// that haven't been seen to finish. If the edit fails and the images can't be taken back (or the
/// app dies in between), the thought keeps inline images with no token; launch cleans those up.
struct PendingImageSaves {
    static let key = "pendingImageSaves"

    var defaults: UserDefaults = .standard

    var ids: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    var isEmpty: Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).isEmpty
    }

    func insert(_ id: UUID) {
        defaults.set(ids.union([id]).map(\.uuidString).sorted(), forKey: Self.key)
    }

    func remove(_ id: UUID) {
        defaults.set(ids.subtracting([id]).map(\.uuidString).sorted(), forKey: Self.key)
    }
}
