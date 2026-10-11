import Foundation
import Observation
import SwiftData

/// Which thought the split view shows in its detail column. Only injected into the environment in the
/// split layout; where it is absent (the compact tabs) thoughts push onto the navigation stack instead.
///
/// Holds identifiers, never the model, so a thought deleted elsewhere can't be rendered dead: the
/// detail column resolves the selection with a query and shows the placeholder when nothing matches.
@MainActor
@Observable
final class ThoughtSelection {
    struct Pick: Equatable {
        /// For the detail column's primary-key lookup.
        let modelID: PersistentIdentifier
        /// For the timeline predicate, which keeps this thought's card listed.
        let id: UUID
    }

    private(set) var current: Pick?
    /// A tag tapped in the detail column. The content column shows its timeline, then clears this.
    var pendingTag: Tag?

    func select(_ thought: Thought) {
        current = Pick(modelID: thought.persistentModelID, id: thought.id)
    }

    func clear() {
        current = nil
    }

    /// Call before deleting a thought from outside the detail column, so no view renders it afterwards.
    func clear(ifSelected thought: Thought) {
        if isSelected(thought) { current = nil }
    }

    func isSelected(_ thought: Thought) -> Bool {
        current?.modelID == thought.persistentModelID
    }
}
