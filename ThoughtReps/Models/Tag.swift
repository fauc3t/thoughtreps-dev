import Foundation
import SwiftData

/// A hashtag parsed from thought bodies. `name` is the lowercased key;
/// uniqueness is enforced by `ThoughtStore`, not the database, so CloudKit stays possible.
@Model
final class Tag {
    var name: String = ""
    var displayName: String = ""
    var colorHex: String? = nil
    var thoughts: [Thought]? = []

    init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}
