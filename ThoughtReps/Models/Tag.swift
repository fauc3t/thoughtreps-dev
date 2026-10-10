import Foundation
import SwiftData

/// A hashtag parsed from thought bodies. `name` is the lowercased key;
/// uniqueness is enforced by `ThoughtStore`, not the database, so CloudKit stays possible.
@Model
final class Tag {
    var name: String = ""
    var displayName: String = ""
    var colorHex: String? = nil
    /// When the color was last chosen; lets a merge keep the newer color. A tag created implicitly
    /// (from body text) has never been colored, so it stays at `distantPast` and loses to any chosen color.
    var updatedAt: Date = Date.distantPast
    var thoughts: [Thought]? = []

    init(name: String, displayName: String, updatedAt: Date = .distantPast) {
        self.name = name
        self.displayName = displayName
        self.updatedAt = updatedAt
    }
}
