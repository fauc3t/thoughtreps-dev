import Foundation
import SwiftData

enum TombstoneKind: String {
    case thought
}

/// Records that a record was deleted, so a later merge with another copy of the data doesn't
/// bring it back. Kept in its own table so no thought query changes. Not exported in backups.
@Model
final class Tombstone {
    /// The id of the deleted record.
    var id: UUID = UUID()
    /// Raw value of `TombstoneKind`.
    var kind: String = TombstoneKind.thought.rawValue
    var deletedAt: Date = Date.now

    init(id: UUID, kind: TombstoneKind, deletedAt: Date) {
        self.id = id
        self.kind = kind.rawValue
        self.deletedAt = deletedAt
    }
}
